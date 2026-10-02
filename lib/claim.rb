# frozen_string_literal: true
require "fileutils"

module RubyClaw
  # Ownership of the tree by a running bot -- and it is taken *before* the slow work.
  #
  # Booting this tree is about a second on a Pi 4 and 7-8 s on the armv6 test bed (measured:
  # 6.8 s from exec to the claim, 15.9 s for a keeper whose whole job was to print "already
  # running"). Two cron keepers can fire in the same instant, and while the claim was
  # written at the *end* of startup a second keeper that started inside that window saw an
  # unclaimed tree and booted its own poller: two bots on one token, Telegram terminating one
  # of them, and the user's chat half-working. So the entry point claims here, before it
  # loads anything.
  #
  # The claim is an exclusive flock() on data/serve.pid, held for as long as the process
  # lives. That is what makes three things true, and each was a failure this replaced:
  #
  #   * taking it is atomic, so however two keepers interleave, exactly one can win;
  #   * the kernel drops the lock when the process dies, so a crashed bot's claim is never
  #     mistaken for a live one and never blocks its own replacement -- no pid has to be
  #     judged alive or dead before progress is possible;
  #   * no run ever has to remove another run's file to make progress. The earlier design
  #     wrote a private file and link()ed it into place, and recovered a stale claim by
  #     unlinking the target and linking again. Between judging the claim stale and removing
  #     it, a rival could create its own claim, and unlinking *that* left two bots both
  #     owning the tree -- a race no ordering of link() and unlink() can close.
  #
  # The pid is still written into the file: it is what makes "already running (pid N)" and
  # the log readable, and what a person with ps can act on.
  module Claim
    PATH = File.join(File.expand_path("..", __dir__), "data", "serve.pid")

    class << self
      # The pid named by the claim, or nil when there is no claim (or nobody has written its
      # pid yet -- see held_by_other?).
      def pid
        n = File.read(PATH).to_i
        n.positive? ? n : nil
      rescue Errno::ENOENT
        nil
      end

      # Is a live process *other than this one* holding the tree? An empty file -- a keeper
      # between taking the lock and writing its pid -- reads as "no pid", so a caller that
      # must decide has to go on to claim! and let the lock settle it rather than trust this
      # answer on its own.
      def held_by_other?
        n = pid
        !n.nil? && n != Process.pid && alive?(n)
      end

      # The sentence a refused start prints; the pid when one is known, because that is how a
      # person finds the process to talk to.
      def running_note
        n = pid
        n ? "already running (pid #{n})" : "already running"
      end

      # Take the claim, or report that somebody else has it. Idempotent: the entry point
      # claims before booting and the serve path claims again later, in the same process, and
      # the second call must not read the first as a rival.
      def claim!
        return write_pid! if @io && !@io.closed?

        FileUtils.mkdir_p(File.dirname(PATH))
        io = File.open(PATH, File::RDWR | File::CREAT, 0o644)
        unless io.flock(File::LOCK_EX | File::LOCK_NB)
          io.close
          return false
        end
        @io = io
        at_exit { release! }
        write_pid!
      end

      # Give the claim back -- but only what is ours. A dying instance that removed the file
      # unconditionally deleted the claim of the process that had just replaced it, and the
      # next keeper was then free to start a third poller.
      def release!
        File.unlink(PATH) if pid == Process.pid
      rescue Errno::ENOENT
        nil
      ensure
        @io&.close
        @io = nil
      end

      private

      def alive?(n)
        Process.kill(0, n)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def write_pid!
        @io.rewind
        @io.truncate(0)
        @io.write("#{Process.pid}\n")
        @io.flush
        true
      end
    end
  end
end
