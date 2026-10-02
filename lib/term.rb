# frozen_string_literal: true
# A shell that *stays open* between tool calls.
#
# `sh` starts a fresh process for every command, which is the right default for a
# one-off: nothing leaks, nothing accumulates. It is the wrong tool for work with state,
# where `cd /srv/app` in one call and `ls` in the next must see the same directory. This
# keeps one shell alive for the life of the harness process, so the working directory,
# exported variables and shell functions carry over from call to call.
#
# Finding where one command's output ends is the hard part: a shell cannot be asked
# "are you done?" out of band. Each call appends a marker line carrying a nonce of its
# own, the exit status of the command and the shell's new working directory, and the
# reader collects output until that exact line arrives. The nonce matters: a command
# that prints the marker text itself (a log being grep-ed, say) must not look like the
# end of the command. It also survives a command that leaves a background process
# holding the pipe open, which is what used to block the one-shot runner forever.
require "open3"
require "securerandom"
require "fileutils"

module RubyClaw
  class Term
    MARK = "__claw_done__"

    class << self
      # One session per process: the point is continuity, so a second one would defeat it.
      def session
        @session ||= new
      end

      def reset!
        @session&.close
        @session = nil
      end
    end

    MAX_BYTES = 200_000     # per command, before the registry truncates further
    SCRIPT_DIR = File.join(ROOT, "data", "term")

    attr_reader :cwd, :shell

    # script_dir: where a call's command file is written. Overridable so a test does not
    # write into the project it is testing.
    def initialize(shell: ENV["CLAW_SHELL"], cwd: ROOT, script_dir: SCRIPT_DIR)
      @shell = shell.to_s.empty? ? default_shell : shell.to_s
      @cwd = cwd
      @dead = false
      @script_dir = script_dir
      @in = @out = @err = @waiter = @pid = nil
      # One call at a time. Under `claw up` a Telegram thread and the local prompt both
      # reach this object, and two readers on one pipe pair hand one conversation the
      # other's output -- measured: thread B got back an empty string while its text sat in
      # A's buffer, so a chat could be shown another chat's command output.
      @lock = Mutex.new
      @at_exit_installed = false
      spawn!
    end

    # Process.kill(0, pid) is true for a zombie, so a killed shell looked alive and the
    # next command was written into a dead pipe. The Waiter thread knows better.
    def alive?
      return false if @dead || @pid.nil?

      !@waiter.nil? && @waiter.alive?
    end

    # Run one command in the live shell.
    # Returns [output, exit_status, cwd, timed_out, restarted].
    def run(command, timeout: 60)
      @lock.synchronize { run_locked(command, timeout: timeout) }
    end

    private def run_locked(command, timeout:)
      restarted = false
      unless alive?
        # The last command ended the shell (`exit`) or the process died. Starting a new
        # one is the honest behaviour -- but the caller has to be told that the state it
        # built up (cd, exports) is gone, or it will keep assuming it.
        restarted = true
        spawn!
      end

      nonce = SecureRandom.hex(8)
      marker = "#{MARK}#{nonce}"
      # The command goes into a file which the shell *sources*, rather than straight down
      # its stdin. A command with an unterminated quote used to swallow everything written
      # after it -- including the marker line -- so the call burned its entire deadline and
      # then killed the session, with no output to show for it. Sourcing contains that:
      # the shell reports the syntax error and carries on to the marker.
      script_path = write_script(nonce, command)
      script = ". '#{script_path}'\n__claw_rc=$?\n" \
               "printf '\\n%s %s %s\\n' '#{marker}' \"$__claw_rc\" \"$PWD\"\n"
      begin
        @in.write(script)
        @in.flush
      rescue SystemCallError, IOError
        @dead = true
        remove_script(script_path)
        return ["the shell died before the command reached it", 127, @cwd, false, true]
      end

      out, status, timed_out, died = collect(marker, timeout)
      # Safe now: the marker is printed after the source has finished reading the file.
      remove_script(script_path)
      @dead ||= died
      [out, status, @cwd, timed_out, restarted || died]
    end

    def close
      return if @pid.nil?

      begin
        Process.kill("TERM", -@pid)     # the whole group: the shell and its children
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      [@in, @out, @err].each { |io| io&.close rescue nil }
      # Reap it here: nobody else will, and an unreaped child stays in the process table
      # as a zombie for as long as the harness runs. Bounded, because a shell that ignores
      # TERM must not hang the exit path.
      begin
        @waiter&.join(2)
      rescue StandardError
        nil
      end
      @dead = true
      @pid = nil
    end

    private

    def default_shell
      %w[/bin/bash /usr/bin/bash /bin/sh].find { |s| File.executable?(s) } || "/bin/sh"
    end

    # 0600 + O_EXCL: this is the one file in the project written from a string the model
    # supplied, so a planted symlink must not be able to redirect the write.
    def write_script(nonce, command)
      FileUtils.mkdir_p(@script_dir)
      path = File.join(@script_dir, "cmd-#{nonce}.sh")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write("#{command}\n") }
      path
    end

    def remove_script(path)
      File.unlink(path)
    rescue StandardError
      nil
    end

    # A crash can leave a script behind. Nothing else owns that directory, so anything still
    # in it when a session starts is rubbish from a previous life -- but only if it is old:
    # a second harness on this machine (or a `claw run` child) may have a command in flight,
    # and deleting its script between the write and the shell reading it loses that command.
    # The same mistake in the scheduler's temp files cost 3 of 6 concurrent writes.
    STALE_SCRIPT = 300

    def sweep_scripts!
      Dir[File.join(@script_dir, "cmd-*.sh")].each do |f|
        next unless (Time.now - File.mtime(f)) > STALE_SCRIPT

        remove_script(f)
      end
    rescue StandardError
      nil
    end

    def spawn!
      sweep_scripts!
      @in, @out, @err, @waiter = Open3.popen3(@shell, "-s", pgroup: true)
      @pid = @waiter.pid
      @dead = false
      # The shell's output must never be swallowed by the harness's own stdout.
      @out.sync = @err.sync = @in.sync = true
      # Once, not once per shell: a long-lived harness restarts this session every time a
      # command ends the shell, and a handler per restart is a leak that only shows up at
      # exit, when it is too late to matter.
      unless @at_exit_installed
        at_exit { close }
        @at_exit_installed = true
      end
      @pid
    end

    # Read until the marker line arrives, the deadline passes, or the shell exits.
    # Returns [output, exit_status, timed_out, shell_died].
    def collect(marker, timeout)
      deadline = Time.now + timeout
      out = +""
      err = +""
      dropped = 0
      # [^\n]* -- not .*, which under /m swallowed everything after the marker -- and \A
      # because the marker can sit at the very start of what has been read so far.
      pattern = /(?:\A|\n)#{Regexp.escape(marker)} (\d+) ?([^\n]*)\n/

      loop do
        if (m = out.match(pattern))
          out = out.sub(pattern, "\n")     # drop the marker line itself
          dir = m[2].to_s.strip
          @cwd = dir unless dir.empty?
          return [finish(out, err, dropped), m[1].to_i, false, false]
        end

        if Time.now >= deadline
          # The command outran its deadline. Killing the group is the only way to stop a
          # shell that is still inside it, and it costs the session: whatever the caller
          # had built up is gone, so it gets told rather than left assuming otherwise.
          kill_group!
          return ["#{finish(out, err, dropped)}\n[the command was still running after #{timeout}s: " \
                  "it was killed, and this shell session is gone -- cd/exports must be set again]",
                  nil, true, true]
        end

        if !alive? && at_eof?
          # The command was `exit`, or the shell was killed from outside, or it crashed.
          # No marker is coming: return what arrived and let the caller restart.
          return [finish(out, err, dropped), nil, false, true]
        end

        ready = IO.select([@out, @err].compact, nil, nil, [[deadline - Time.now, 0.25].min, 0.01].max)
        next unless ready

        ready.first.each do |io|
          chunk = begin
            io.read_nonblock(65_536, exception: false)
          rescue IOError, SystemCallError
            nil
          end
          next if chunk.nil? || chunk == :wait_readable

          if io.equal?(@out)
            out << RubyClaw.utf8(chunk)
          else
            err << RubyClaw.utf8(chunk)
          end
        end
        # A command that spews -- cat /dev/urandom, a runaway log tail -- must not be able to
        # grow the harness's memory until the deadline. MAX_BYTES was declared and never
        # read, so nothing enforced it. Keep the head and the tail and drop the middle: the
        # head is where a program says what it is doing, the tail is where it says how it
        # ended, and the marker lives in the tail.
        if out.bytesize > MAX_BYTES || err.bytesize > MAX_BYTES
          keep = MAX_BYTES / 2
          out, dropped_out = trim(out, keep)
          err, dropped_err = trim(err, keep)
          dropped += dropped_out + dropped_err
        end
      end
    end

    # Returns [kept, bytes_dropped]. byteslice can split a multibyte character, which
    # RubyClaw.utf8 scrubs at the end -- a mangled character in a 200 KB dump is a small
    # price for not growing unbounded.
    def trim(buf, keep)
      return [buf, 0] if buf.bytesize <= MAX_BYTES

      cut = buf.bytesize - MAX_BYTES + keep
      ["#{buf.byteslice(0, keep)}#{buf.byteslice(-keep, keep)}", cut]
    end

    def finish(out, err, dropped)
      note = dropped.positive? ? "[output truncated: #{dropped} bytes dropped from the middle, " \
                                 "keeping the first and last #{MAX_BYTES / 2000} KB]\n" : ""
      RubyClaw.utf8(note + out + err)
    end

    # Nothing more can arrive once the shell is gone and both pipes have hit EOF. Without
    # this, a command that ends the shell spins here until its deadline.
    def at_eof?
      [@out, @err].compact.all? { |io| io.eof? }
    rescue IOError, SystemCallError
      true
    end

    # Stop the shell and everything it started, and mark the session unusable so the next
    # call starts a fresh one instead of writing into a dead pipe.
    def kill_group!
      return if @pid.nil?

      begin
        Process.kill("KILL", -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      @dead = true
      [@in, @out, @err].each { |io| io&.close rescue nil }
      @in = @out = @err = nil
    end
  end
end
