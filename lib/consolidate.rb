# frozen_string_literal: true
# Consolidation: the pass that keeps a growing harness from rotting into a junk
# drawer.
#
# The division of labour is the whole design: the *evidence* is computed here,
# locally, and never asked of the model (name/description/param/source similarity
# for clustering; the usage log and git history for what earns its place). The
# model makes the judgement call. The harness then executes it through the same
# validated pipeline as any other self-write, with one addition: a merged tool
# must replay the calls its originals were really called with and still produce
# their content. That replay corpus is the usage log, so telemetry is load-bearing
# rather than decorative.
require_relative "harness"

module RubyClaw
  module Consolidate
    SIM_FLOOR   = 0.30   # below this a pair is not worth the model's attention
    RECENT_DAYS = 30     # a tool used inside this window cannot be deleted
    MAX_OPS     = 4
    REPLAY_PER_TOOL = 3  # recorded calls replayed per original, per merge
    AB_TIMEOUT = 60      # seconds a merge replay may take before its group is killed
    PASS_SCORE  = 0.75   # share of the original's content the merge must reproduce

    SYSTEM = <<~PROMPT
      You are the consolidation pass of a self-building agent harness. The harness writes its own
      tools; your job is to decide which of them should be merged or retired so the tool surface
      stays a coherent set instead of a junk drawer that grows forever.

      You are given the inventory (each self-written tool: description, params, source, call
      count, error count, age, days since last use) and candidate clusters with computed
      similarity scores.

      Rules:
      - Bias to action where the evidence is clear. If your own analysis concludes a tool is
        redundant — an exact twin exists, and no call site depends on the duplicate specifically —
        propose the merge. The replay gate is what protects correctness, so a wrong merge costs one
        run; a duplicate you leave in place costs every future session.
      - MERGE only when a single tool genuinely serves both call sites. The merged tool must
        reproduce the output of the tools it replaces for the arguments they were really called
        with. Keep the clearest of the two names unless a better one is obvious.
      - DELETE only tools with no successful call in the last #{RECENT_DAYS} days. The harness
        refuses anything else, so proposing it just wastes a turn.
      - Never propose changes to core tools (origin "builtin"); they are not yours to edit here.
      - Keep two tools when the second produces a genuinely different answer (a different output
        shape, a different case, an extra field a caller may rely on) — that is not a duplicate.
        "Nothing to do" is the right answer only when no cluster is actually redundant.

      Reply with JSON only, no prose:
      {"ops":[{"action":"merge"|"delete"|"keep","tools":["name","name"],"name":"merged_name",
               "source":"<full Ruby source, required for merge>","reason":"one line"}]}
    PROMPT

    STOP = %w[the and for with that this from into tool returns return which when current
              value using more than its are not you can all any use string parse].freeze

    class << self
      # ---- evidence --------------------------------------------------------

      # Everything known about the self-written tools, from three sources the
      # harness keeps anyway: the files, the usage log, and git history. Covers the
      # shipped tools/ set and this instance's own instance/tools/, and says which is
      # which, so a shipped tool is never confused with the instance's growth.
      def inventory
        usage = usage_index
        tool_files.map do |name, (location, path)|
          src  = File.read(path)
          rel  = path.delete_prefix("#{ROOT}/")
          u    = usage[name] || {}
          added = RubyClaw.git("log", "-1", "--format=%ct", "--", rel, allow_fail: true).strip
          age = added.empty? ? nil : ((Time.now - Time.at(added.to_i)) / 86_400.0).round(1)
          last = u[:last] ? ((Time.now - u[:last]) / 86_400.0).round(1) : nil
          { "name" => name, "file" => rel, "location" => location, "lines" => src.lines.size,
            "description" => RubyClaw.tools[name]&.description.to_s,
            "params" => (RubyClaw.tools[name]&.params || {}).keys,
            "source" => src,
            "calls" => u[:calls].to_i, "errors" => u[:errors].to_i,
            "age_days" => age, "idle_days" => last }
        end
      end

      # Every self-written tool file: the shipped set first, then the instance's own.
      # An instance file of the same name wins (it is the one the loader registers),
      # so the audit sees the union of both directories and never counts a shadowed
      # copy twice. Returns { name => [location, path] }, location "shipped"|"instance".
      def tool_files
        files = {}
        Dir[File.join(CORE_TOOLS_DIR, "*.rb")].sort.each { |f| files[File.basename(f, ".rb")] = ["shipped", f] }
        Dir[File.join(TOOLS_DIR, "*.rb")].sort.each { |f| files[File.basename(f, ".rb")] = ["instance", f] }
        files
      end

      # Aggregate the usage log once: totals, error count, last use, and a small
      # set of distinct successful argument sets to replay later.
      def usage_index
        path = File.join(LOG_DIR, "usage.jsonl")
        idx = Hash.new { |h, k| h[k] = { calls: 0, errors: 0, last: nil, replay: {} } }
        return idx unless File.exist?(path)
        File.foreach(path) do |line|
          r = (JSON.parse(line) rescue nil) or next
          name = r["tool"].to_s
          next if name.empty? || builtin?(name)
          e = idx[name]
          e[:calls] += 1
          e[:errors] += 1 unless r["ok"]
          ts = (Time.parse(r["ts"]) rescue nil)
          e[:last] = ts if ts && (e[:last].nil? || ts > e[:last])
          if r["ok"] && r["args"].is_a?(Hash)
            (e[:replay][JSON.generate(r["args"])] ||= r["args"])
          end
        end
        idx
      end

      def builtin?(name)
        t = RubyClaw.tools[name]
        t.nil? || t.origin == "builtin"
      end

      # ---- clustering ------------------------------------------------------

      def clusters(inv)
        pairs = []
        inv.combination(2) do |a, b|
          s = score(a, b)
          next if s < SIM_FLOOR
          pairs << { "tools" => [a["name"], b["name"]], "score" => s.round(3), "why" => why(a, b) }
        end
        pairs.sort_by { |p| -p["score"] }.first(6)
      end

      def score(a, b)
        src  = shingle_sim(normalize_code(a["source"]), normalize_code(b["source"]))
        name = [trigram_sim(a["name"], b["name"]), token_sim(a["name"], b["name"])].max
        desc = token_sim(a["description"], b["description"])
        par  = jaccard(a["params"], b["params"])
        [src, 0.4 * name + 0.4 * desc + 0.2 * par].max
      end

      def why(a, b)
        parts = []
        parts << "near-identical source" if shingle_sim(normalize_code(a["source"]), normalize_code(b["source"])) > 0.6
        parts << "similar names" if trigram_sim(a["name"], b["name"]) > 0.6
        parts << "similar descriptions" if token_sim(a["description"], b["description"]) > 0.5
        parts << "same parameters" if jaccard(a["params"], b["params"]) > 0.9
        parts.empty? ? "weak signal" : parts.join(", ")
      end

      def normalize_code(src)
        src.lines.map { |l| l.sub(/#.*$/, "").strip }.reject(&:empty?)
      end

      # 3-line shingles: catches copy-paste-and-tweak, the usual way a duplicate
      # gets born.
      def shingles(lines, n = 3)
        return [] if lines.size < n
        lines.each_cons(n).map { |s| s.join("\n") }.uniq
      end

      def shingle_sim(a, b)
        return 0.0 if a.size < 3 || b.size < 3
        jaccard(shingles(a), shingles(b))
      end

      def jaccard(a, b)
        a = a.to_a.uniq; b = b.to_a.uniq
        return 0.0 if a.empty? || b.empty?
        ((a & b).size.to_f / (a | b).size).round(3)
      end

      def token_sim(a, b) = jaccard(words(a), words(b))

      def words(s)
        s.to_s.downcase.split(/[^a-z0-9]+/).reject { |w| w.length < 3 || STOP.include?(w) }.uniq
      end

      def trigram_sim(a, b) = jaccard(tris(a.to_s), tris(b.to_s))

      def tris(s) = (0..[s.length - 3, 0].max).map { |i| s[i, 3] }.uniq

      # ---- the model's call ------------------------------------------------

      def ask(inv, pairs, model)
        in_cluster = pairs.flat_map { |p| p["tools"] }.uniq
        digest = {
          "usage_window_days" => RECENT_DAYS,
          "tools" => inv.map do |t|
            d = t.reject { |k, _| k == "source" }
            d["source"] = t["source"] if in_cluster.include?(t["name"])
            d
          end,
          "candidate_clusters" => pairs
        }
        res = RubyClaw.chat_once(
          [{ "role" => "system", "content" => SYSTEM },
           { "role" => "user", "content" => JSON.generate(digest) }],
          model: model, json_object: true
        )
        ops = (JSON.parse(res["content"])["ops"] rescue nil)
        raise Error, "model returned no usable ops: #{res['content'].to_s[0, 200]}" unless ops.is_a?(Array)
        [ops, res["usage"]]
      end

      # ---- executing the plan ----------------------------------------------

      def run(apply: false, model: nil, quiet: false)
        inv = inventory
        usage = usage_index
        print_inventory(inv) unless quiet
        if inv.empty?
          say "no self-written tools yet — nothing to consolidate", quiet
          return true
        end
        pairs = clusters(inv)
        if pairs.empty?
          say "\nno candidate clusters above #{SIM_FLOOR} — nothing to consolidate (no model call, no cost)", quiet
          return true
        end
        say "\ncandidate clusters:", quiet
        pairs.each { |p| say format("  %-40s %.2f  (%s)", p["tools"].join(" + "), p["score"], p["why"]), quiet }

        ops, used = ask(inv, pairs, model)
        say "\nmodel proposed #{ops.size} op(s); tokens #{used['prompt_tokens']} in / #{used['completion_tokens']} out", quiet
        return true if ops.empty?

        applied = refused = 0
        ops.first(MAX_OPS).each_with_index do |op, i|
          say "\n[#{i + 1}] #{op['action']} #{Array(op['tools']).join(', ')}", quiet
          good = apply ? execute(op, inv, usage) : plan_only(op)
          good ? applied += 1 : refused += 1
          say "    #{good ? 'OK  ' : 'NO  '}#{last_message}", quiet
        end
        say("\nrun with --apply to execute (this was a dry run; nothing changed)") unless apply
        if apply && refused.positive?
          say "\n#{applied} applied, #{refused} refused — the audit ran; see the reasons above", quiet
        end
        # The exit code says whether the audit could run, not whether the model's plan
        # was good: a refusal is an answer, and it is already in the log.
        true
      end

      def last_message = @last_message
      def fail!(msg) = (@last_message = msg; false)

      def plan_only(op)
        @last_message =
          case op["action"]
          when "merge"  then "would merge into `#{op['name']}`: #{op['reason']}"
          when "delete" then "would retire #{Array(op['tools']).join(', ')}: #{op['reason']}"
          else (op["reason"] || "no action")
          end
        true
      end

      def execute(op, inv, usage)
        @last_message = nil
        case op["action"]
        when "keep", nil then @last_message = op["reason"] || "keep"; true
        when "delete"    then retire(op, inv, usage)
        when "merge"     then merge(op, inv, usage)
        else fail!("unknown action #{op['action'].inspect}")
        end
      end

      def by_name(inv, name) = inv.find { |t| t["name"] == name.to_s }

      # A usage log whose every line is unparseable means the evidence is gone, not
      # that nothing was used: refuse rather than delete on no evidence.
      def usage_log_broken?
        path = File.join(LOG_DIR, "usage.jsonl")
        return false unless File.exist?(path)
        total = bad = 0
        File.foreach(path) do |line|
          next if line.strip.empty?
          total += 1
          begin
            JSON.parse(line)
          rescue JSON::ParserError
            bad += 1
          end
        end
        total.positive? && bad == total
      end

      def guard_delete(name, inv, usage)
        return "no such self-written tool `#{name}`" unless by_name(inv, name)
        if usage_log_broken?
          return "refused: log/usage.jsonl cannot be read, so there is no evidence that " \
                 "`#{name}` is unused"
        end
        u = usage[name] || {}
        if u[:calls].to_i.positive? && u[:last] && ((Time.now - u[:last]) / 86_400.0) < RECENT_DAYS
          return "refused: `#{name}` was called #{((Time.now - u[:last]) / 86_400.0).round(1)} days ago " \
                 "(guard is #{RECENT_DAYS})"
        end
        nil
      end

      def retire(op, inv, usage)
        names = Array(op["tools"])
        return fail!("delete needs at least one tool") if names.empty?
        names.each { |n| (why = guard_delete(n, inv, usage)) and return fail!(why) }
        names.each do |n|
          FileUtils.rm_f(File.join(ROOT, by_name(inv, n)["file"]))
          RubyClaw.tools.delete(n)
          RubyClaw.order.delete(n)
        end
        commit("consolidate(retire): #{names.join(', ')} — #{op['reason']}")
        log_event("delete", names, op["reason"], {})
        @last_message = "retired #{names.join(', ')} (committed; `git revert HEAD` to undo)"
        true
      end

      def merge(op, inv, usage)
        names = Array(op["tools"])
        return fail!("merge needs two tools") if names.size < 2
        missing = names.reject { |n| by_name(inv, n) }
        return fail!("not self-written: #{missing.join(', ')}") if missing.any?
        src = op["source"].to_s
        return fail!("merge proposed no source") if src.strip.empty?
        name = op["name"].to_s
        return fail!("merge proposed no name") if name.empty?

        # 1. does it load, register, and carry a sane schema?
        check = SelfWrite.propose(kind: "tool", name: name, source: src, reason: op["reason"],
                                  replace: names.include?(name), dry_run: true)
        return fail!("new tool failed validation: #{check[0, 300]}") unless check.start_with?("DRY RUN")

        # 2. replay the calls the originals were really called with. No recorded
        #    calls means no evidence that the merge preserves anything — and a
        #    never-called tool is a retirement candidate, not a merge candidate.
        rows = names.flat_map do |n|
          ((usage[n] || {})[:replay] || {}).values.first(REPLAY_PER_TOOL).map { |args| { "tool" => n, "args" => args } }
        end
        if rows.empty?
          return fail!("no recorded calls to replay for #{names.join(', ')} — cannot prove the merge " \
                       "preserves behaviour. If they are unused, retire them instead.")
        end

        # Staged like any other proposal: random name, 0700, O_EXCL|O_NOFOLLOW, so a
        # planted symlink cannot redirect this write (the old predictable
        # `.staging/<name>.merged.rb` could be made to point at lib/).
        staged = SelfWrite.stage(name, src, ".merged.rb")
        ab = child_ab(staged, name, rows)
        FileUtils.rm_f(staged)
        return fail!("replay crashed: #{ab['error']}") unless ab["ok"]
        return fail!("the merged tool did not register in the child process") unless ab["registered"]

        # Score here, not in the child. The merged tool is loaded in the child, so it can
        # redefine RubyClaw.similarity there -- a merge that returned "TOTALLY DIFFERENT
        # ANSWER" scored 1.0 that way and was committed.
        ab["rows"].each { |r| r["score"] = RubyClaw.similarity(r["before"], r["after"]) }
        judgeable = ab["rows"].reject { |r| r["score"].nil? }
        detail = ab["rows"].map { |r| "#{r['tool']}=#{r['score'].nil? ? 'n/a' : r['score']}" }.join(" ")
        worst = judgeable.map { |r| r["score"] }.min
        if judgeable.any? && worst < PASS_SCORE
          bad = ab["rows"].min_by { |r| r["score"] || 1.0 }
          return fail!("replay failed (worst #{worst} < #{PASS_SCORE}; #{detail}). `#{bad['tool']}` " \
                       "before: #{bad['before'].inspect[0, 150]} / merged: #{bad['after'].inspect[0, 150]}")
        end

        # 3. promote for real, then retire what it replaces — two commits, so
        #    either step is revertible on its own
        promo = SelfWrite.propose(kind: "tool", name: name, source: src, reason: op["reason"],
                                  replace: names.include?(name), tag: "consolidate")
        return fail!("promotion failed: #{promo[0, 300]}") unless promo.start_with?("promoted")

        gone = names - [name]
        gone.each do |n|
          FileUtils.rm_f(File.join(ROOT, by_name(inv, n)["file"]))
          RubyClaw.tools.delete(n)
          RubyClaw.order.delete(n)
        end
        commit("consolidate(merge): #{gone.join(', ')} -> #{name}") unless gone.empty?
        log_event("merge", names, op["reason"], { "into" => name, "replay" => detail })
        @last_message = "merged #{names.join(' + ')} into `#{name}`; replay #{detail} " \
                        "(#{judgeable.size} judged, #{ab['rows'].size - judgeable.size} unjudgeable)"
        true
      end

      def commit(message)
        RubyClaw.git("add", "-A")
        # Retiring a tool that was never committed stages nothing; git would exit
        # non-zero and this would cry wolf about a change that did land.
        return if RubyClaw.git("status", "--porcelain").strip.empty?
        RubyClaw.git("-c", "user.name=rubyclaw", "-c", "user.email=rubyclaw@localhost",
                     "commit", "-q", "-m", message)
      rescue Error => e
        warn "rubyclaw: commit failed (#{e.message}); the change is still live"
      end

      # Bounded by the process-group runner rather than Timeout.timeout: a replay that
      # leaves a grandchild holding the pipes used to outlive every deadline.
      def child_ab(staged, name, rows)
        cmd = [RbConfig.ruby, File.join(ROOT, "lib", "child_ab.rb"), staged, name, JSON.generate(rows)]
        r = Proc.run(cmd, timeout: AB_TIMEOUT)
        if r.timed_out
          return { "ok" => false, "error" => "replay timed out after #{AB_TIMEOUT}s (process group killed)" }
        end

        v = begin
          JSON.parse(r.out.lines.last.to_s)
        rescue JSON::ParserError
          nil
        end
        v || { "ok" => false, "error" => "no verdict (exit #{r.code}): #{(r.out + r.err).strip[0, 300]}" }
      end

      # ---- reporting -------------------------------------------------------

      def print_inventory(inv)
        puts format("%-16s %-9s %6s %6s %7s %8s %6s", "tool", "where", "calls", "errors", "age", "idle", "lines")
        inv.each do |t|
          puts format("%-16s %-9s %6d %6d %7s %8s %6d",
                      t["name"], t["location"], t["calls"], t["errors"],
                      t["age_days"] ? "#{t['age_days']}d" : "?",
                      t["idle_days"] ? "#{t['idle_days']}d" : "never",
                      t["lines"])
        end
      end

      def say(msg, quiet = false) = (quiet ? nil : puts(msg))

      def log_event(action, names, reason, extra)
        FileUtils.mkdir_p(LOG_DIR)
        File.open(File.join(LOG_DIR, "evolution.jsonl"), "a") do |f|
          f.puts JSON.generate(ts: Time.now.iso8601, kind: "consolidate/#{action}",
                               name: Array(names).join("+"), reason: reason, verdict: extra)
        end
      end
    end
  end
end
