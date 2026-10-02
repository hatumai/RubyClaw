# frozen_string_literal: true
# RubyClaw — updating an instance from its home repository.
#
# An instance is not a snapshot of the project, it is a growth of it: it writes tools into
# instance/tools/, skills into instance/skills/, notes into memory.md, and it can patch its own
# core. Upstream grows too. So an update cannot mean "take the newest tree" -- that would quietly
# overwrite the part of the program the instance made for itself, which is exactly the part it
# depends on.
#
# The rule, and the whole of it: for every path upstream changed, compare what this instance has
# against the last upstream commit it synced with (refs/claw/base, or the merge base on a fresh
# clone). If this instance has not touched that path, take upstream's version. If it has, that is a
# conflict: the path is left exactly as it is, and reported. Nothing is overwritten to make an
# update succeed and nothing is ever force-applied.
#
# Paths under lib/, bin/, rubyclaw, test/, Rakefile and scripts/ take effect at the next start, the
# same rule the self-write pipeline follows -- nothing under lib/ is swapped into a running process.
# Every update is an ordinary commit, so `claw rollback` reverses it like any other change.
require "json"

module RubyClaw
  module Update
    UPSTREAM_REF = "refs/claw/upstream"
    BASE_REF     = "refs/claw/base"
    STATE        = File.join(ROOT, "data", "upstream.json")
    DEFAULT_UPSTREAM = "https://github.com/hatumai/RubyClaw.git"

    # Runtime state and growth, never source. A diff that mentions these is not an update, and this
    # is checked before any content comparison: instance/ is where the harness keeps what it built for
    # itself, so upstream must not reach into it even when the local copy looks untouched and would
    # otherwise be taken as a safe change.
    LOCAL_ONLY = ["data/", "log/", ".staging/", ".git/", ".env", "instance/"].freeze

    # A change here needs a restart to take effect. tools/ and skills/ are loaded every turn, so
    # they do not.
    RESTART = ["lib/", "bin/", "rubyclaw", "test/", "Rakefile", "scripts/"].freeze

    # What an update did, or would do with check: true.
    class Report
      attr_accessor :url, :commit, :base, :behind, :error, :check, :blocked
      attr_reader :applied, :skipped

      def initialize
        @applied = []
        @skipped = []
        @behind = 0
        @restart = false
        @check = false
        @blocked = false
      end

      def ok? = @error.nil?
      def updates? = @behind.positive?
      def restart? = @restart
      def core_changed! = @restart = true

      def to_s
        return "rubyclaw update: #{@error}" unless ok?

        out = ["rubyclaw update: #{@url}"]
        if @behind.zero?
          out << "  up to date with upstream (#{short(@commit)})."
          return out.join("\n")
        end
        verb = (@check || @blocked) ? "would apply" : "applied"
        out << "  #{@behind} commit#{@behind == 1 ? '' : 's'} behind #{short(@base)} " \
               "(#{verb} #{@applied.size}, kept #{@skipped.size} of my own)"
        unless @applied.empty?
          out << (@blocked ? "  would take: #{list(@applied)}" : "  took: #{list(@applied)}")
        end
        unless @skipped.empty?
          out << "  kept as it is, changed here: #{list(@skipped.map(&:first))}"
        end
        if @blocked
          out << "  nothing applied: the tree has uncommitted changes — commit or stash them first."
        end
        out << "  core files changed: restart claw to use them." if @restart
        out.join("\n")
      end

      private

      def short(sha) = sha.to_s[0, 10]

      def list(paths)
        shown = paths.first(8).join(", ")
        paths.size > 8 ? "#{shown} (+#{paths.size - 8} more)" : shown
      end
    end

    def self.repo? = File.directory?(File.join(ROOT, ".git"))

    # A checkout is a clone: it carries upstream history, or a sync point this instance wrote on
    # its last update. Either durable signal is enough. Remote-tracking refs (refs/remotes/*, which
    # clone and fetch write) are the on-disk form of upstream history, and refs/claw/base is the
    # last commit this instance synced with — both survive a restart and neither is something a
    # launcher's `git init` produces, since that repository has no history in common with upstream
    # and nothing to sync from. "Has a remote" is deliberately not the test: a configured remote is
    # provenance, not a clone relationship, and the launcher's init (or the .git shipped inside an
    # extracted release archive) can leave one behind. Refuse a tree with neither as a missing
    # clone, before a fetch that cannot succeed is attempted and reported as a network problem.
    def self.checkout?
      return false unless repo?
      return true unless RubyClaw.git("rev-parse", "--verify", "--quiet", BASE_REF, allow_fail: true).strip.empty?

      !RubyClaw.git("for-each-ref", "--format=%(refname)", "refs/remotes", allow_fail: true).strip.empty?
    end

    # CLI, environment, or config.yml — so an instance can point at a fork without editing code.
    def self.url
      env = ENV["CLAW_UPSTREAM"].to_s.strip
      return env unless env.empty?

      configured = (RubyClaw.config["upstream"] || "").to_s.strip
      configured.empty? ? DEFAULT_UPSTREAM : configured
    end

    # The blob at ref:path, or nil when that path does not exist there. Git does the hashing in
    # both directions, so a file is compared as git would compare it -- no digest code here.
    def self.blob_at(ref, path)
      out = RubyClaw.git("rev-parse", "--verify", "--quiet", "#{ref}:#{path}", allow_fail: true).strip
      out.empty? ? nil : out
    end

    def self.blob_now(path)
      full = File.join(ROOT, path)
      return nil unless File.file?(full)

      out = RubyClaw.git("hash-object", "--", full, allow_fail: true).strip
      out.empty? ? nil : out
    end

    # Where this instance last synced with upstream. refs/claw/base is written on every update; a
    # fresh clone has no such ref, and there the merge base is exactly the same thing.
    def self.base_commit(ref)
      stored = RubyClaw.git("rev-parse", "--verify", "--quiet", BASE_REF, allow_fail: true).strip
      return stored unless stored.empty?

      RubyClaw.git("merge-base", "HEAD", ref, allow_fail: true).strip
    end

    def self.fetch!(report)
      RubyClaw.git("fetch", "--quiet", "--no-tags", url, "+HEAD:#{UPSTREAM_REF}", allow_fail: true)
      # RubyClaw.git returns stdout, and git says everything interesting on stderr, so the ref is the
      # test that counts: if it resolves, the fetch worked.
      commit = RubyClaw.git("rev-parse", "--verify", "--quiet", UPSTREAM_REF, allow_fail: true).strip
      if commit.empty?
        report.error = "cannot fetch #{url} — check the network, or set CLAW_UPSTREAM to a mirror"
      end
      commit
    end

    def self.dirty?
      !RubyClaw.git("status", "--porcelain", allow_fail: true).strip.empty?
    end

    # [status, path] pairs. --no-renames on purpose: a rename arrives as a deletion and an addition,
    # which the safety rule already handles per path, rather than as a case of its own.
    def self.changes(base, ref)
      RubyClaw.git("diff", "--name-status", "--no-renames", base, ref, allow_fail: true)
        .lines.filter_map do |line|
          status, path = line.split("\t", 2)
          next if status.nil? || path.nil?

          [status.strip, path.strip]
        end
        .reject { |_, path| LOCAL_ONLY.any? { |p| path == p || path.start_with?(p) } }
    end

    # Would taking upstream's copy of this path destroy something this instance made? Only if the
    # working file differs from what that path was at the last sync.
    def self.safe?(base, path)
      blob_now(path) == blob_at(base, path)
    end

    def self.run(check: false)
      report = Report.new
      report.url = url
      report.check = check

      unless checkout?
        report.error = "this copy is not a clone of the repository, so self-update cannot run: " \
                       "git clone #{DEFAULT_UPSTREAM}"
        return report
      end
      return report if (commit = fetch!(report)).empty?

      report.commit = commit
      base = base_commit(UPSTREAM_REF)
      if base.empty?
        report.error = "#{UPSTREAM_REF} has no history in common with this checkout"
        return report
      end
      report.base = base
      report.behind = RubyClaw.git("rev-list", "--count", "#{base}..#{UPSTREAM_REF}",
                                   allow_fail: true).strip.to_i
      return report if report.behind.zero?

      items = changes(base, commit)
      items.each do |_status, path|
        if safe?(base, path)
          report.applied << path
          report.core_changed! if RESTART.any? { |p| path == p || path.start_with?(p) }
        else
          report.skipped << [path, "changed here"]
        end
      end
      return report if check

      # A dirty tree means uncommitted work, and an update commits everything it touches: refuse
      # rather than sweep somebody's edits into a commit about upstream.
      # A dirty tree means uncommitted work, and an update commits what it applies: refuse rather
      # than sweep somebody's edits into a commit about upstream. The report still lists what would
      # have been taken.
      if dirty?
        report.blocked = true
        return report
      end

      report.applied.each { |path| take(status_of(items, path), path) }
      record(commit, report)
      report
    end

    def self.status_of(items, path)
      items.find { |_, p| p == path }&.first || "M"
    end

    def self.take(status, path)
      if status == "D"
        RubyClaw.git("rm", "-q", "--", path, allow_fail: true)
      else
        RubyClaw.git("checkout", UPSTREAM_REF, "--", path, allow_fail: true)
      end
    end

    # One commit per update, then the sync point moves. The commit can fail with "nothing to commit"
    # when upstream's change was not content (a mode, say) -- that is not an error.
    def self.record(commit, report)
      if report.applied.any?
        RubyClaw.git("-c", "user.name=rubyclaw", "-c", "user.email=rubyclaw@localhost",
                     "commit", "-q", "-m", message(commit, report), allow_fail: true)
      end
      RubyClaw.git("update-ref", BASE_REF, commit, allow_fail: true)
      FileUtils.mkdir_p(File.dirname(STATE))
      File.write(STATE, JSON.pretty_generate(url: url, commit: commit, at: Time.now.utc.iso8601,
                                             applied: report.applied,
                                             skipped: report.skipped.map(&:first)) + "\n")
      log_event(commit, report)
      report
    end

    # The same shape the self-write pipeline writes, so `claw evo` shows updates beside everything
    # else this instance has done to itself.
    def self.log_event(commit, report)
      return if ENV["CLAW_SELFTEST"]

      FileUtils.mkdir_p(LOG_DIR)
      File.open(File.join(LOG_DIR, "evolution.jsonl"), "a") do |f|
        f.puts JSON.generate(ts: Time.now.iso8601, kind: "update", name: "upstream",
                             reason: "#{report.applied.size} applied, #{report.skipped.size} kept",
                             verdict: commit[0, 10])
      end
    rescue StandardError
      nil
    end

    def self.message(commit, report)
      ["update: take #{report.applied.size} path(s) from upstream #{commit[0, 10]}",
       "",
       "Applied: #{report.applied.join(', ')}",
       (report.skipped.any? ? "Kept, because this instance changed them: #{report.skipped.map(&:first).join(', ')}" : nil),
       "",
       "Selective by design: a path this instance has grown for itself is never overwritten by an",
       "update. Reverse it with `claw rollback`."].compact.join("\n")
    end
  end
end
