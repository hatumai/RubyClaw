# frozen_string_literal: true
# The self-write pipeline. This is the load-bearing part of the harness.
#
# A model that can edit itself with no feedback loop rots: it writes plausible
# code that silently doesn't load, and the failure surfaces three sessions later
# as mystery behaviour. So nothing is ever promoted on trust. Every proposal is
# syntax-checked, loaded in a *throwaway child process* (a new tool cannot take
# the running harness down with it), exercised against the caller's own test
# arguments, and only then moved into place and committed to git — which also
# makes every growth step individually revertible.
module RubyClaw
  module SelfWrite
    NAME_RE = /\A[a-z][a-z0-9_]{1,40}\z/
    VALIDATE_TIMEOUT = 30
    BOOT_TIMEOUT = 60
    CORE_MARK = File.join(STAGE_DIR, "core_commit")   # the commit the boot guard undoes

    class << self
      def propose(kind:, name:, source:, reason: nil, test: nil, replace: false, dry_run: false, tag: "self")
        kind = kind.to_s
        name = name.to_s
        raise Error, "source is empty" if source.to_s.strip.empty?
        # A bad name is a refusal like any other, so it lands in the evolution log
        # and the model is told why in the same breath.
        if kind == "core"
          return reject("core", name, "core name must look like foo.rb", nil) unless name =~ /\A[a-z_]+\.rb\z/
        elsif name !~ NAME_RE
          return reject(kind, name, "name must match #{NAME_RE.inspect} (snake_case, 2-41 chars)", nil)
        end

        case kind
        when "tool"  then propose_tool(name, source, reason, test, replace, dry_run, tag)
        when "skill" then dry_run ? dry_probe_skill(name, source, replace) : propose_skill(name, source, reason, replace)
        when "core"  then propose_core(name, source, reason)
        else raise Error, "unknown kind #{kind.inspect} (tool|skill|core)"
        end
      end

      # ---- tool: goes live in this process if it proves itself --------------

      def propose_tool(name, source, reason, test, replace, dry_run = false, tag = "self")
        staged = stage(name, source)
        syntax = syntax_check(staged)
        return reject("tool", name, "syntax error", syntax) unless syntax == :ok

        verdict = child_validate(staged, test, replace ? name : nil)
        return reject("tool", name, verdict["error"], verdict["backtrace"]) unless verdict["ok"]

        if dry_run
          FileUtils.rm_f(staged)
          return "DRY RUN ok for tool `#{name}` (validated in a child process, nothing promoted): " \
                 "#{verdict['detail']}"
        end

        FileUtils.mkdir_p(TOOLS_DIR)
        dest = File.join(TOOLS_DIR, "#{name}.rb")
        FileUtils.mv(staged, dest)

        # Live-register in the running process. Appended last, so every tool
        # schema already sent upstream stays byte-identical (prompt cache).
        unregister(name) if replace
        begin
          # The same label the validator used, so a proposal cannot behave one way
          # while being judged and another way once it is live -- and so a
          # self-written tool is not filed as a builtin in the usage log (which made
          # its own calls invisible to the consolidation audit).
          RubyClaw.current_origin = "#{name}.rb"
          load dest
        rescue StandardError, ScriptError => e
          FileUtils.rm_f(dest)
          return reject("tool", name, "loaded in a clean child but failed here: #{e.message}")
        ensure
          RubyClaw.current_origin = nil
        end

        # The child's verdict is the child's word. This is the harness's own: a
        # proposal can print any verdict it likes, but it cannot make a tool that
        # raises answer correctly in the process that is about to use it. (A hostile
        # proposal can still lie -- see the honest limits in the README. This catches
        # the ordinary case, which is a tool that simply does not work.)
        if (failure = replay(name, test))
          rollback_promotion(name, dest, replace)
          return reject("tool", name, "the child passed it but it fails here: #{failure}")
        end

        commit("tool", name, reason, tag)
        log_event("tool", name, reason, verdict)
        "promoted tool `#{name}` -> instance/tools/#{name}.rb (committed). Live now; it is appended " \
          "after the builtins, so the prompt prefix is unchanged.\n" \
          "tool surface is now #{RubyClaw.tools.size} tools: #{RubyClaw.tools.keys.join(', ')}\n" \
          "validation: #{verdict['detail']}"
      end

      # ---- skill: prompt-level growth, no code, no restart ------------------

      def dry_probe_skill(name, source, replace)
        dest = File.join(SKILLS_DIR, "#{name}.md")
        return reject("skill", name, "skill exists (pass replace: true to overwrite)") if File.exist?(dest) && !replace
        "DRY RUN ok for skill `#{name}` (#{source.bytesize} bytes of markdown, nothing written)"
      end

      def propose_skill(name, source, reason, replace)
        FileUtils.mkdir_p(SKILLS_DIR)
        dest = File.join(SKILLS_DIR, "#{name}.md")
        return reject("skill", name, "skill exists (pass replace: true to overwrite)") if File.exist?(dest) && !replace
        File.write(dest, source)
        commit("skill", name, reason)
        log_event("skill", name, reason, {})
        "promoted skill `#{name}` -> instance/skills/#{name}.md (committed). It is injected into the system " \
          "prompt from the next request onward."
      end

      # ---- core: staged, child-tested, next-start-only ----------------------

      def propose_core(name, source, reason)
        return reject("core", name, "core name must be an existing file in lib/") unless
          File.file?(File.join(ROOT, "lib", name))
        staged = stage(name, source, ".new")
        return reject("core", name, "syntax error", syntax_check(staged)) unless syntax_check(staged) == :ok

        live = File.join(ROOT, "lib", name)
        backup = "#{live}.prev"
        FileUtils.cp(live, backup)
        FileUtils.cp(staged, live)
        boot = run_boot_probe
        unless boot[:ok]
          FileUtils.mv(backup, live)   # self-restore: a bad core never survives validation
          return reject("core", name, "new core fails to boot; previous version restored", boot[:error])
        end
        FileUtils.rm_f(backup)
        commit("core", name, reason)
        # Record exactly which commit to undo. The boot guard used to recover it from
        # the commit subject, so the moment any other commit landed on top the
        # auto-revert could not find its target and the failure counter just climbed.
        FileUtils.mkdir_p(STAGE_DIR)
        File.write(CORE_MARK, RubyClaw.git("rev-parse", "HEAD").strip)
        log_event("core", name, reason, boot)
        "staged core patch to lib/#{name} (committed; boots clean in a child process). " \
          "It takes effect on the next `claw` start — the running process is never hot-patched. " \
          "If the next two starts fail, claw auto-reverts this commit."
      end

      # ---- machinery -------------------------------------------------------

      # A random filename in a private 0700 directory, written with O_EXCL|O_NOFOLLOW.
      # The old predictable `.staging/<name>.rb` could be pre-planted as a symlink to
      # lib/boot.rb, and File.write follows symlinks: one *rejected* proposal was
      # enough to clobber the core and leave a tree that could not boot, with a
      # message claiming nothing had been written.
      def stage(name, source, ext = ".rb")
        dir = File.join(STAGE_DIR, "incoming")
        FileUtils.mkdir_p(dir)
        File.chmod(0o700, dir)
        path = File.join(dir, "#{name}-#{SecureRandom.hex(8)}#{ext}")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |f|
          f.write(source)
        end
        path
      end

      # The tool is live and registered; call it the way the model would and see
      # whether it answers. Returns failure text, or nil when it is fine.
      def replay(name, test)
        return nil if test.to_s.strip.empty?

        t = RubyClaw.tools[name]
        return "not registered after loading" if t.nil?

        out = RubyClaw.invoke(t, JSON.parse(test))
        s = (out.is_a?(String) ? out : JSON.generate(out)).scrub
        s.start_with?("ERROR") ? s : nil
      rescue JSON::ParserError
        nil                                  # unparseable test args already refused upstream
      rescue StandardError, ScriptError => e
        "#{e.class}: #{e.message}"
      end

      # Undo a promotion that failed the replay: delete a new tool, and restore the
      # committed version of a replaced one.
      def rollback_promotion(name, dest, replace)
        unregister(name)
        if replace
          RubyClaw.git("checkout", "--", dest.delete_prefix("#{ROOT}/"), allow_fail: true)
          begin
            RubyClaw.current_origin = "#{name}.rb"
            load dest if File.file?(dest)
          ensure
            RubyClaw.current_origin = nil
          end
        else
          FileUtils.rm_f(dest)
        end
      rescue StandardError, ScriptError => e
        warn "rubyclaw: could not undo the promotion of #{name} (#{e.class}: #{e.message})"
      end

      def syntax_check(path)
        r = Proc.run([RbConfig.ruby, "-c", path], timeout: 30)
        r.ok? ? :ok : "#{r.out}#{r.err}".strip
      rescue StandardError => e
        "ruby -c failed: #{e.message}"
      end

      # The verdict comes from a file this process created, carrying a nonce, and only
      # when the child also exited 0. Reading the last line of stdout meant a proposal
      # could print its own verdict and exit!(0) -- which is exactly how a tool that
      # always raises got promoted, and how a core patch consisting of
      # `puts "BOOT_OK"; exit!(0)` was committed.
      #
      # The child gets a stripped environment (unsetenv_others): no CLAW_API_KEY, no
      # Telegram token, and CLAW_NO_DOTENV so it cannot read .env either. Loading a
      # proposal executes it -- so give it nothing worth stealing.
      def child_validate(staged, test, replace_name)
        dir = File.join(STAGE_DIR, "verdicts")
        FileUtils.mkdir_p(dir)
        File.chmod(0o700, dir)
        path = File.join(dir, "#{File.basename(staged)}.verdict.json")
        nonce = SecureRandom.hex(16)
        env = { "PATH" => ENV["PATH"], "HOME" => ENV["HOME"],
                "LANG" => ENV["LANG"] || "C.UTF-8", "TZ" => ENV["TZ"],
                "CLAW_NO_DOTENV" => "1", "CLAW_NO_USAGE" => "1",
                "CLAW_VERDICT" => path, "CLAW_VERDICT_NONCE" => nonce }.compact
        cmd = [RbConfig.ruby, File.join(ROOT, "lib", "child_validate.rb"), staged,
               (test || "").to_s, (replace_name || "").to_s]
        r = Proc.run(cmd, timeout: VALIDATE_TIMEOUT, env: env, unsetenv_others: true)
        if r.timed_out
          return { "ok" => false,
                   "error" => "validation timed out after #{VALIDATE_TIMEOUT}s (process group killed)" }
        end

        read_verdict(path, nonce) ||
          { "ok" => false, "error" => "child produced no verdict (exit #{r.code})",
            "backtrace" => "#{r.out}\n#{r.err}".strip[0, 800] }
      ensure
        FileUtils.rm_f(path) if path
      end

      def read_verdict(path, nonce)
        return nil unless File.file?(path)

        v = JSON.parse(File.read(path))
        return nil unless v.is_a?(Hash) && v["nonce"] == nonce

        v.delete("nonce")
        v
      rescue JSON::ParserError
        nil
      end

      # Symbol keys, and read as symbol keys by every caller: a mismatch here once
      # rejected every core patch ever proposed (boot[:ok] on a string-keyed hash is
      # nil, so "did it boot?" was always no and the patch was always reverted).
      # Bounded, and it cross-checks the boot report against the inventory the
      # filesystem implies. Any output containing BOOT_OK used to pass, so a patch that
      # printed "BOOT_OK 999 tools: totally fake" and exited 0 was committed -- and
      # every later start printed the same line, so the two-strike revert could never
      # fire. Running is not enough; it has to still be this harness.
      def run_boot_probe
        r = Proc.run([RbConfig.ruby, File.join(ROOT, "bin", "claw"), "probe"], timeout: BOOT_TIMEOUT)
        if r.timed_out
          return { ok: false, error: "the patched harness did not finish booting within " \
                                     "#{BOOT_TIMEOUT}s (process group killed)" }
        end
        unless r.ok? && r.out.include?("BOOT_OK")
          return { ok: false,
                   error: "exit=#{r.code} stdout=#{r.out.strip[0, 300]} stderr=#{r.err.strip[0, 600]}" }
        end

        reported = r.out[/BOOT_OK \d+ tools: (.*)$/, 1].to_s.split(",").map(&:strip)
        missing = expected_tool_names - reported
        if missing.any?
          return { ok: false, error: "it booted, but its tool inventory is wrong: " \
                                     "#{missing.inspect} missing from #{reported.inspect}" }
        end

        { ok: true, detail: r.out.strip.lines.last.to_s.strip }
      end

      # Known without loading anything: the names declared in lib/builtins.rb, plus one
      # per file in either tool directory (shipped and the instance's own). Covering
      # both is what stops a new tool from silently shadowing a shipped one of the
      # same name.
      def expected_tool_names
        declared = File.read(File.join(ROOT, "lib", "builtins.rb"))
                       .scan(/^\s*tool "([a-z0-9_]+)"/).flatten
        declared + RubyClaw.dynamic_tool_names
      end

      def unregister(name)
        RubyClaw.tools.delete(name.to_s)
        RubyClaw.order.delete(name.to_s)
      end

      def commit(kind, name, reason, tag = "self")
        RubyClaw.git("add", "-A")
        return if RubyClaw.git("status", "--porcelain").strip.empty?   # nothing to record
        RubyClaw.git("-c", "user.name=rubyclaw", "-c", "user.email=rubyclaw@localhost",
                      "commit", "-q", "-m", "#{tag}(#{kind}): #{name}#{reason ? " — #{reason}" : ''}",
                      allow_fail: false)
      rescue Error => e
        warn "rubyclaw: commit failed (#{e.message}); the file is still live"
      end

      def log_event(kind, name, reason, verdict)
        return if ENV["CLAW_SELFTEST"]   # selftest fixtures are not real proposals
        FileUtils.mkdir_p(LOG_DIR)
        File.open(File.join(LOG_DIR, "evolution.jsonl"), "a") do |f|
          f.puts JSON.generate(ts: Time.now.iso8601, kind: kind, name: name,
                               reason: reason, verdict: verdict)
        end
      end

      # What a rejection actually guarantees, said exactly. A proposal is *loaded* to
      # be judged, so rejecting it is not a claim that it never ran -- only that it was
      # not promoted: nothing live, nothing written into the growth directories or lib/,
      # nothing committed. Saying "nothing was written" while the source had already
      # executed was the kind of comment that makes a reviewer stop trusting the file.
      def reject(kind, name, why, detail = nil)
        log_event(kind, name, "REJECTED: #{why}", { detail: detail })
        "REJECTED #{kind} `#{name}`: #{why}\n#{detail.to_s[0, 800]}\n" \
          "Not promoted — nothing is live, in place or committed. The validator did load " \
          "it in a child process to judge it. Fix the source and call extend again."
      end
    end
  end
end
