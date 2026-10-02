# frozen_string_literal: true
# Child processes with a deadline that actually holds.
#
# The obvious `Timeout.timeout { Open3.capture3(...) }` is not a bound. capture3
# reads the child's pipes to EOF, so any grandchild that inherits those pipes and
# outlives its parent (`cmd &`, a server a tool just started, a wrapper script)
# keeps the reader blocked past every deadline -- and a child that never exits
# hangs the caller forever. That is how a 2-second shell timeout turned into a
# 6-second wait, and how a looping tool could hang `extend` indefinitely.
#
# So: the child writes to temp files, never to pipes (there is no reader to block),
# it runs in its own process group, and when the deadline passes the whole group is
# signalled -- grandchildren included, not just the process we spawned.
require "tmpdir"

module RubyClaw
  module Proc
    Result = Struct.new(:out, :err, :status, :timed_out, :seconds) do
      def ok? = !timed_out && !status.nil? && status.success?
      def code = status&.exitstatus || (status&.termsig ? 128 + status.termsig : nil)
      def summary = timed_out ? "timed out after #{seconds}s" : "exit #{code}"
    end

    class << self
      # env: extra variables. unsetenv_others: true gives the child *only* those
      # variables -- what the validator uses so a proposal cannot read this
      # machine's credentials out of the environment it is judged in.
      def run(cmd, timeout:, env: {}, cwd: nil, unsetenv_others: false)
        t0 = clock
        cmd = Array(cmd).map(&:to_s)
        Dir.mktmpdir("claw-proc-") do |dir|
          op = File.join(dir, "out")
          ep = File.join(dir, "err")
          pid = ::Process.spawn(env, *cmd, pgroup: true, chdir: cwd || Dir.pwd,
                                in: File::NULL, out: [op, "wb"], err: [ep, "wb"],
                                unsetenv_others: unsetenv_others)
          status = wait(pid, timeout)
          Result.new(read(op), read(ep), status, status.nil?, (clock - t0).round(2))
        end
      rescue SystemCallError => e                      # no such binary, no permission
        Result.new("", "#{e.class}: #{e.message}", nil, false, (clock - t0).round(2))
      end

      # `bash -lc` when bash exists, `sh -c` when it does not. The tool description
      # promises exactly this, and a description that promises bash while dash
      # answers is worse than either.
      SHELL = File.exist?("/bin/bash") ? ["/bin/bash", "-lc"].freeze : ["/bin/sh", "-c"].freeze
      def shell_command(cmd) = SHELL + [cmd.to_s]

      private

      def wait(pid, timeout)
        deadline = clock + timeout.to_f
        loop do
          done, status = ::Process.waitpid2(pid, ::Process::WNOHANG)
          return status if done
          if clock >= deadline
            kill_group(pid)
            return nil                                 # timed out
          end
          sleep 0.02
        end
      rescue Errno::ECHILD
        nil
      end

      # TERM the group, give it a moment to die, then KILL it -- and reap the child
      # either way, so a killed tool leaves no zombie behind.
      def kill_group(pid)
        %w[TERM KILL].each do |sig|
          begin
            ::Process.kill("-#{sig}", pid)
          rescue Errno::ESRCH, Errno::EPERM
            break                                      # nothing left to signal
          end
          return reap(pid) if gone?(pid, 1.0)
        end
        reap(pid)
      end

      def gone?(pid, seconds)
        deadline = clock + seconds
        loop do
          done, = ::Process.waitpid2(pid, ::Process::WNOHANG)
          return true if done
          return false if clock >= deadline
          sleep 0.02
        end
      rescue Errno::ECHILD
        true
      end

      def reap(pid)
        ::Process.waitpid(pid, ::Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end

      # RubyClaw.utf8: a tool that returns binary must not be able to poison the
      # message list, because JSON.generate raises on invalid UTF-8 and the poisoned
      # turn then fails on every retry.
      def read(path)
        RubyClaw.utf8(File.binread(path))
      rescue SystemCallError
        ""
      end

      def clock = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
