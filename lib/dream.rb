# frozen_string_literal: true
# The dream: an offline consolidation pass over what the harness accumulated.
#
# `claw dream` reads the notes store, the session transcripts and the work store, and
# writes exactly one thing of its own -- memory/dreams/YYYY-MM-DD.md. The input store is
# never mutated; a dream's findings are proposals that go through the existing approval
# machinery (Work.request_approval), never edits. The shape is the one the 2025-2026
# "dreaming" family converged on, and the four phases run in order:
#
#   ORIENT        read the notes index and the existing dreams; build a map before
#                 touching anything
#   GATHER SIGNAL search the transcripts for corrections, save requests, decisions and
#                 repeated patterns -- deliberately NOT an exhaustive read
#   CONSOLIDATE   relative dates become absolute; duplicates merge; contradictions
#                 resolve with the newest ground truth winning; episodic traces distill
#                 into one rule. The model makes the judgement; this file fixes the
#                 deterministic half (absolute dates, budgets, provenance).
#   PRUNE/INDEX   a hard budget on the proposed index, because the index loads on every
#                 session
#
# THE SANDBOX RULE -- and this is the point of the feature.
#
# A consolidation pass is the single most dangerous thing to give network access, because
# it reads everything and writes what it concluded. So this pass gets exactly one tool:
# a scoped read of its own inputs. The model is offered ONE schema (`dream_read`), and
# every tool call it makes is dispatched by `Dream.sandbox_call`, which refuses any name
# but that one. It never calls RubyClaw.call, so there is no path -- by construction, not
# by policy -- from a dream to http, the shell, the browser or anything else. policy.yml
# names the boundary as `dream.run`, and `claw policy` shows it.
#
# Proposals are NOT applied. Each proposed memory write opens a task and parks a
# Work.request_approval carrying `dream_path`, so it arrives in Telegram with
# Approve/Deny and in `/approvals`, and a person decides. `auto_apply` exists as an
# explicit, OFF-by-default switch; it is never the default.
require "json"
require "time"
require "fileutils"
require_relative "harness"
require_relative "work"
require_relative "policy"

module RubyClaw
  module Dream
    DREAMS_DIR = File.join(ROOT, "memory", "dreams")
    BANK_DIR   = File.join(ROOT, "memory", "bank")
    ARTIFACT_REL = "memory/dreams".freeze

    # The trigger: at least 24 h since the last dream AND at least 5 new sessions. Both,
    # so a quiet day does not dream about nothing. "Sessions" are the transcript files
    # the Harness already writes (log/session-YYYYMMDD-HHMMSS.jsonl), one per conversation;
    # there is no second session tracker, and this is the closest honest proxy.
    MIN_INTERVAL_SECONDS = 24 * 60 * 60
    MIN_NEW_SESSIONS = 5
    SESSION_GLOB = File.join(LOG_DIR, "session-*.jsonl")

    # Budgets. SIGNAL_LIMIT and READ_LIMIT bound what the model is shown; MAX_PROPOSALS
    # and INDEX_MAX_LINES are the prune-and-index rule -- an index that loads on every
    # session has to stay small.
    SIGNAL_LIMIT = 40
    READ_LIMIT = 200
    MAX_PROPOSALS = 8
    INDEX_MAX_LINES = 40
    MAX_STEPS = 4

    # The one tool the dream's model is offered. Not registered in the global registry:
    # the dream's surface is its own, so `claw tools` and the real prompt are unchanged.
    READ_TOOL = "dream_read"
    SANDBOX_TOOLS = [READ_TOOL].freeze
    READ_TOOL_SCHEMA = {
      "type" => "function",
      "function" => {
        "name" => READ_TOOL,
        "description" => "Read one of the dream's inputs: the notes store (memory.md, " \
                         "preferences.md, skills), an existing dream artifact, or a session " \
                         "transcript (log/session-*.jsonl). Nothing else can be read. Use it " \
                         "sparingly to confirm a signal before proposing a memory write.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string",
                        "description" => "path relative to the project root, e.g. log/session-20260315-090000.jsonl" },
            "limit" => { "type" => "integer",
                         "description" => "max lines (default #{READ_LIMIT})" }
          },
          "required" => ["path"]
        }
      }
    }.freeze

    # The system prompt. It fixes the model's job: consolidate, propose, never apply.
    SYSTEM = <<~PROMPT
      You are the dream pass of a self-building agent harness: an offline consolidation run
      over what the harness accumulated while working. You are NOT the working agent, and you
      have no network, no shell and no way to act on the world. The one tool you have reads a
      note, an existing dream, or a session transcript -- nothing else.

      Your job is to turn episodic traces into durable memory:

      - Relative dates become absolute: "yesterday we decided" -> "on 2026-03-15 we decided".
      - Duplicates merge into one entry.
      - Contradictions resolve with the NEWEST ground truth winning; the older claim is named
        as superseded.
      - Repeated one-off facts distill into one general rule (four times "the token is in
        STAGING_API_KEY" -> "this service reads every credential from the environment, never
        from config").
      - Keep every proposed write to one short line, as if it will be injected into every
        future system prompt. An index that grows without bound is a failure, not thoroughness.

      You propose; you never apply. A person reviews every memory write.

      Reply with JSON only, no prose:
      {"writes":[{"kind":"memory"|"preference","note":"...","reason":"one line"}],
       "rules":["one general rule distilled from repeats"],
       "index":["lines for the consolidated memory index"],
       "dropped":["a superseded/duplicate claim, and which newer claim replaces it"]}
    PROMPT

    # Signal categories, deterministically found in the transcripts. This is the "gather
    # signal, not an exhaustive read" phase: it looks for what is already suspected to
    # matter rather than reading every line into the model.
    SIGNALS = {
      "correction" => /\b(no,|don't|do not|not what|actually,|instead|that's wrong|wrong|stop doing|never mind)\b/i,
      "save_request" => /\b(remember|save this|save that|make a note|note that|keep in mind|for the record)\b/i,
      "decision" => /\b(we decided|decided|we'll use|going with|let's use|the plan is|architecture|switch to|adopt)\b/i,
      "recurring" => /\b(again|as before|same as|already|every time|recurring)\b/i
    }.freeze

    class << self
      # ---- trigger ----------------------------------------------------------

      # The transcript files the Harness writes, oldest first.
      def session_files
        Dir[SESSION_GLOB].select { |f| File.file?(f) }.sort_by { |f| File.mtime(f) }
      end

      # The newest dream artifact, or nil. A dream's date is in its filename; its run time
      # is its mtime, which is what the 24 h check uses so a re-run at the same second does
      # not slip through on a same-day filename.
      def last_dream_path = Dir[File.join(DREAMS_DIR, "*.md")].max_by { |f| File.mtime(f) }
      def last_dream_at = (f = last_dream_path) && File.mtime(f)

      # Is a dream due? Returns the decision and, when it is not due, the single failing
      # condition in a person's words. Both conditions are required.
      def due?(now: Time.now)
        last = last_dream_path
        last_at = last && File.mtime(last)
        fresh = session_files.select { |f| last_at.nil? || File.mtime(f) > last_at }
        age_ok = last_at.nil? || (now - last_at) >= MIN_INTERVAL_SECONDS
        sessions_ok = fresh.size >= MIN_NEW_SESSIONS
        reason =
          if !age_ok
            "last dream was #{Work.human_seconds((now - last_at).round)} ago (< 24h) — " \
              "nothing to consolidate yet"
          elsif !sessions_ok
            "#{fresh.size} new session(s) since the last dream (< #{MIN_NEW_SESSIONS}) — " \
              "a quiet day does not dream about nothing"
          end
        { "run" => (age_ok && sessions_ok), "reason" => reason, "last_dream" => last,
          "last_dream_at" => last_at, "new_sessions" => fresh, "age_ok" => age_ok,
          "sessions_ok" => sessions_ok }
      end

      # The honest, one-line answer to "would it run?" for a report.
      def status(now: Time.now)
        d = due?(now: now)
        if d["run"]
          "dream: due (last #{d['last_dream'] ? File.basename(d['last_dream']) : 'never'}, " \
            "#{d['new_sessions'].size} new session(s))"
        else
          "dream: not due — #{d['reason']}"
        end
      end

      # ---- auto_apply: explicit, off by default -----------------------------

      def auto_apply?
        env = ENV["CLAW_DREAM_AUTO_APPLY"].to_s
        return true if %w[1 true yes on].include?(env.strip.downcase)

        cfg = RubyClaw.config["dream"]
        cfg.is_a?(Hash) && cfg["auto_apply"] == true
      end

      # ---- the pass ---------------------------------------------------------

      # Run the dream. Prints a plain report. `auto_apply:` nil means "use the switch";
      # true/false overrides it. Returns a result hash either way.
      def run(model: nil, quiet: false, now: Time.now, auto_apply: nil)
        d = due?(now: now)
        unless d["run"]
          say("rubyclaw dream — skipped: #{d['reason']}", quiet)
          return { "ran" => false, "reason" => d["reason"], "due" => d }
        end

        # The explicit switch, resolved once: a CLI `--auto-apply`, else the env/config
        # switch. It is NEVER on by default.
        apply = auto_apply.nil? ? auto_apply? : auto_apply

        # The one gate on the pass itself. Under the shipped policy `dream.run` is `auto`;
        # an operator who sets it `ask` parks the whole pass for a person, like any other
        # action. This is what makes the sandbox boundary visible in `claw policy`.
        verdict = Policy.check("dream")
        unless verdict["run"]
          say(verdict["message"], quiet)
          return { "ran" => false, "reason" => verdict["message"], "held" => verdict["action"] }
        end

        FileUtils.mkdir_p(DREAMS_DIR)
        FileUtils.mkdir_p(BANK_DIR)   # created and left empty; the bank is stage 3

        orient = orient_map
        signals = gather_signals(d["new_sessions"])
        proposals, usage = deliberate(orient, signals, model: model, now: now)
        proposals = prune(proposals)

        artifact_rel = File.join(ARTIFACT_REL, "#{now.strftime('%Y-%m-%d')}.md")
        # `Time#utc` MUTATES its receiver in this Ruby, and both render_artifact and Work
        # call it. So the pass's own `now` is never handed to them: they get a throwaway
        # copy, and the artifact name, the header and the report keep the local date.
        body = render_artifact(now: now.getlocal, due: d, orient: orient, signals: signals,
                               proposals: proposals, auto_apply: apply)
        File.write(File.join(ROOT, artifact_rel), body)

        approvals = park_proposals(proposals["writes"], artifact_rel, now: now,
                                   auto_apply: apply)

        report = { "ran" => true, "artifact" => artifact_rel, "new_sessions" => d["new_sessions"].size,
                   "signals" => signals.size, "writes" => proposals["writes"].size,
                   "approvals" => approvals, "usage" => usage, "now" => now }
        print_report(report, quiet)
        report
      end

      # ---- ORIENT -----------------------------------------------------------

      # A map of what exists, before touching anything. Small on purpose: names and counts,
      # not contents, except a few tail lines of each note.
      def orient_map
        {
          "notes" => {
            "memory" => note_digest(MEMORY),
            "preferences" => note_digest(PREFERENCES),
            "skills" => Notes.skill_files.keys
          },
          "existing_dreams" => Dir[File.join(DREAMS_DIR, "*.md")].map { |f| File.basename(f) }.sort,
          "work" => work_digest
        }
      end

      def note_digest(path)
        return { "lines" => 0, "recent" => [] } unless File.file?(path)

        body = File.read(path, encoding: "UTF-8").split("\n").reject { |l| l.start_with?("#", "<!--") }
        { "lines" => body.size, "recent" => body.last(4).map { |l| l.strip[0, 160] } }
      end

      def work_digest
        tasks = Work.tasks
        { "tasks" => tasks.size, "states" => tasks.map { |t| t["state"] }.tally,
          "pending_approvals" => Work.pending_approvals.size }
      rescue StandardError
        { "tasks" => 0, "states" => {}, "pending_approvals" => 0 }
      end

      # ---- GATHER SIGNAL ----------------------------------------------------

      # Search only NEW transcripts for the four categories, capped hard. Never the work
      # store's contents and never an exhaustive read: this is the targeted pass.
      def gather_signals(files, limit: SIGNAL_LIMIT)
        out = []
        Array(files).each do |f|
          break if out.size >= limit

          File.foreach(f) do |line|
            break if out.size >= limit

            text = transcript_text(line)
            next if text.empty?

            SIGNALS.each do |category, re|
              next unless text.match?(re)

              out << { "category" => category, "source" => File.basename(f),
                       "line" => text[0, 220] }
              break
            end
          end
        rescue StandardError
          next
        end
        out
      end

      # One transcript line is JSON (`{"role":...,"content":...}`) written by Harness#log.
      # Fall back to the raw line so a malformed entry still yields a signal rather than
      # being silently skipped.
      def transcript_text(line)
        entry = (JSON.parse(line) rescue nil)
        if entry.is_a?(Hash)
          [entry["role"], entry["name"], entry["content"]].compact.join(" ").strip
        else
          line.to_s.strip
        end
      end

      # ---- CONSOLIDATE ------------------------------------------------------

      # The model turn, bounded and sandboxed. The model may call the one read tool; every
      # call goes through sandbox_call, which refuses anything else. It finishes when a
      # message arrives with no tool calls, whose content is parsed as the proposal JSON.
      def deliberate(orient, signals, model: nil, now: Time.now, max_steps: MAX_STEPS)
        messages = [
          { "role" => "system", "content" => SYSTEM },
          { "role" => "user",
            "content" => JSON.generate({ "today" => now.strftime("%Y-%m-%d"),
                                         "orient" => orient, "signals" => signals }) }
        ]
        last_usage = {}
        max_steps.times do
          res = RubyClaw.chat_once(messages, model: model, tools: [READ_TOOL_SCHEMA], max_tokens: 4000)
          last_usage = res["usage"] || {}
          calls = res["tool_calls"]
          if calls.nil? || calls.empty?
            return [parse_proposals(res["content"], now: now), last_usage]
          end

          assistant = { "role" => "assistant", "content" => res["content"] }
          assistant["tool_calls"] = calls
          messages << assistant
          calls.each do |tc|
            name = tc.dig("function", "name")
            args = parse_args(tc.dig("function", "arguments"))
            out = sandbox_call(name, args)
            messages << { "role" => "tool", "tool_call_id" => tc["id"], "name" => name,
                          "content" => out }
          end
        end
        [{ "writes" => [], "rules" => [], "index" => [], "dropped" => [] }, last_usage]
      end

      def parse_args(raw)
        JSON.parse(raw.to_s.strip.empty? ? "{}" : raw.to_s)
      rescue JSON::ParserError
        {}
      end

      # The sandbox. Exactly one tool name is dispatched; everything else is refused here,
      # before any registry, policy or socket is reached. This is what makes the pass that
      # reads everything structurally unable to send anything.
      def sandbox_call(name, args)
        unless SANDBOX_TOOLS.include?(name.to_s)
          return "REFUSED: the dream sandbox has no `#{name}` tool. This pass can read its " \
                 "inputs (#{SANDBOX_TOOLS.join(', ')}) and write its own artifact, and nothing " \
                 "else — no network, no shell, no browser."
        end

        read_input(args.is_a?(Hash) ? (args["path"] || args[:path]) : nil,
                   limit: args.is_a?(Hash) ? (args["limit"] || args[:limit]) : nil)
      end

      # Read only the dream's own inputs, and only a bounded number of lines. Anything
      # outside that set -- .env, lib/, data/ -- is refused by path, not by argument.
      def read_input(path, limit: nil)
        p = File.expand_path(path.to_s, ROOT)
        unless readable?(p)
          return "REFUSED: `#{path}` is not a dream input. The dream reads only the notes " \
                 "store, existing dream artifacts, and session transcripts " \
                 "(log/session-*.jsonl)."
        end
        return "no such file: #{path}" unless File.file?(p)

        lim = [[(limit || READ_LIMIT).to_i, 1].max, READ_LIMIT].min
        out = []
        File.open(p, "rb") do |io|
          io.each_line.with_index do |line, i|
            break if out.size >= lim

            out << format("%5d|%s", i + 1, RubyClaw.utf8(line.chomp))
          end
        end
        out.join("\n")
      end

      def readable?(abs)
        return true if abs == MEMORY || abs == PREFERENCES
        return true if abs.start_with?(SKILLS_DIR + File::SEPARATOR)
        return true if abs.start_with?(CORE_SKILLS_DIR + File::SEPARATOR)
        return true if abs.start_with?(DREAMS_DIR + File::SEPARATOR)
        return true if abs.start_with?(LOG_DIR + File::SEPARATOR) &&
                       File.basename(abs).match?(/\Asession-[\w.-]+\.jsonl\z/)

        false
      end

      # Parse the model's JSON, tolerating prose around it, and absolutize dates in every
      # proposed string. This is the deterministic half of consolidation: whatever the model
      # says, "yesterday" does not reach the artifact or the approval as a relative word.
      def parse_proposals(content, now: Time.now)
        data = coerce_json(content)
        data = {} unless data.is_a?(Hash)
        writes = Array(data["writes"]).filter_map do |w|
          next unless w.is_a?(Hash)

          note = absolutize(w["note"], now: now)
          next if note.strip.empty?

          { "kind" => (w["kind"].to_s == "preference" ? "preference" : "memory"),
            "note" => note.strip, "reason" => absolutize(w["reason"], now: now).strip }
        end
        { "writes" => writes,
          "rules" => Array(data["rules"]).map { |r| absolutize(r, now: now).strip }.reject(&:empty?),
          "index" => Array(data["index"]).map { |r| absolutize(r, now: now).strip }.reject(&:empty?),
          "dropped" => Array(data["dropped"]).map { |r| absolutize(r, now: now).strip }.reject(&:empty?) }
      end

      def coerce_json(content)
        txt = content.to_s.strip
        return JSON.parse(txt) if txt.start_with?("{") || txt.start_with?("[")

        m = txt[/\{.*\}/m]
        m ? JSON.parse(m) : nil
      rescue JSON::ParserError
        nil
      end

      # Relative words become the date they meant, using the run's date as "today". Longest
      # first so "yesterday" is not caught by "day".
      def absolutize(text, now: Time.now)
        s = text.to_s
        { "yesterday" => now - 86_400, "tomorrow" => now + 86_400, "today" => now }.each do |word, t|
          s = s.gsub(/\b#{word}\b/i, t.strftime("%Y-%m-%d"))
        end
        s
      end

      # ---- PRUNE AND INDEX --------------------------------------------------

      # The hard budget. Anything that would load on every session stays small; excess
      # proposals are dropped and named in the artifact, not silently.
      def prune(proposals)
        over = proposals["writes"].size - MAX_PROPOSALS
        writes = proposals["writes"].first(MAX_PROPOSALS)
        index = proposals["index"].first(INDEX_MAX_LINES)
        notes = []
        notes << "dropped #{over} proposed write(s) over the #{MAX_PROPOSALS} budget" if over.positive?
        if proposals["index"].size > INDEX_MAX_LINES
          notes << "dropped #{proposals['index'].size - INDEX_MAX_LINES} index line(s) over the #{INDEX_MAX_LINES} budget"
        end
        { "writes" => writes, "rules" => proposals["rules"], "index" => index,
          "dropped" => proposals["dropped"], "budget_notes" => notes }
      end

      # ---- output -----------------------------------------------------------

      # Park every proposed memory write through the existing Work path, carrying the dream
      # artifact's path so the provenance survives. Applied leaves the input store alone;
      # auto_apply (explicit, off by default) is the only path that writes memory.
      def park_proposals(writes, artifact_rel, now: Time.now, auto_apply: false)
        return [] if writes.empty?

        return writes.map { |w| apply_write(w) } if auto_apply

        date = now.strftime("%Y-%m-%d")
        writes.map do |w|
          # Work calls `now.utc` (mutating) internally, so each call gets its own copy.
          task = Work.add_task(title: "dream #{date}: #{w['note'][0, 60]}",
                               project: "dream",
                               detail: "proposed by the dream pass; source #{artifact_rel}",
                               now: now.getlocal)
          ap = Work.request_approval(task_id: task["id"], action: "dream.apply_memory",
                                     note: "[#{w['kind']}] #{w['note']}" \
                                           "#{w['reason'].to_s.empty? ? '' : " — #{w['reason']}"}",
                                     dream_path: artifact_rel, now: now.getlocal)
          { "approval" => ap["id"], "note" => w["note"], "kind" => w["kind"], "dream_path" => artifact_rel }
        end
      end

      def apply_write(write)
        Notes.append(write["kind"].to_sym, write["note"])
        { "applied" => true, "note" => write["note"], "kind" => write["kind"] }
      end

      def render_artifact(now:, due:, orient:, signals:, proposals:, auto_apply: false)
        date = now.strftime("%Y-%m-%d")
        out = +"# Dream — #{date}\n\n"
        out << "Consolidation pass over what the harness accumulated. The input store is\n"
        out << "read-only; **nothing here is applied.** Every proposed memory write parks a\n"
        out << "work approval carrying this artifact's path (`dream_path`).\n\n"
        out << "- ran: #{now.utc.iso8601}\n"
        out << "- last dream: #{due['last_dream'] ? due['last_dream_at'].utc.iso8601 : 'never'}\n"
        out << "- new sessions reviewed: #{due['new_sessions'].size}\n"
        out << "- auto_apply: #{auto_apply ? 'ON (explicit)' : 'off (proposals only)'}\n\n"

        out << "## Orient\n"
        notes = orient["notes"]
        out << "- memory.md: #{notes['memory']['lines']} line(s); preferences.md: " \
               "#{notes['preferences']['lines']} line(s); skills: #{notes['skills'].join(', ').then { |s| s.empty? ? '(none)' : s }}\n"
        out << "- existing dreams: #{orient['existing_dreams'].empty? ? '(none)' : orient['existing_dreams'].join(', ')}\n"
        out << "- work: #{orient['work']['tasks']} task(s) " \
               "#{orient['work']['states'].inspect}, #{orient['work']['pending_approvals']} pending approval(s)\n\n"

        out << "## Signal (#{signals.size}#{signals.size >= SIGNAL_LIMIT ? ", capped at #{SIGNAL_LIMIT}" : ''})\n"
        if signals.empty?
          out << "- none found in the new transcripts\n"
        else
          signals.each { |s| out << "- [#{s['category']}] #{s['source']}: #{s['line']}\n" }
        end
        out << "\n"

        out << "## Consolidated (proposed, NOT applied)\n"
        out << "### Proposed memory writes (#{proposals['writes'].size})\n"
        if proposals["writes"].empty?
          out << "- none\n"
        else
          proposals["writes"].each do |w|
            out << "- [#{w['kind']}] #{w['note']}" \
                   "#{w['reason'].to_s.empty? ? '' : "  (reason: #{w['reason']})"}\n"
          end
        end
        out << "\n### Distilled rules (#{proposals['rules'].size})\n"
        out << (proposals["rules"].empty? ? "- none\n" : proposals["rules"].map { |r| "- #{r}\n" }.join)
        out << "\n### Contradictions / duplicates (newest ground truth wins)\n"
        out << (proposals["dropped"].empty? ? "- none\n" : proposals["dropped"].map { |r| "- #{r}\n" }.join)

        out << "\n## Prune and index (budget: #{INDEX_MAX_LINES} lines, #{MAX_PROPOSALS} writes)\n"
        out << (proposals["index"].empty? ? "- no index proposal\n" : proposals["index"].map { |r| "- #{r}\n" }.join)
        Array(proposals["budget_notes"]).each { |n| out << "- budget: #{n}\n" }
        out << "\n_Provenance: dream_path = #{File.join(ARTIFACT_REL, "#{date}.md")}_\n"
        out
      end

      def print_report(report, quiet)
        return if quiet

        puts "rubyclaw dream — #{report['now'].strftime('%Y-%m-%d')}"
        puts "read: #{report['new_sessions']} session(s), notes store, work store; " \
             "gathered #{report['signals']} signal(s)"
        artifact = report["artifact"]
        if report["writes"].zero?
          puts "no memory writes proposed."
        else
          puts "proposed #{report['writes']} memory write(s) — NOT APPLIED; parked for a person:"
          report["approvals"].each do |a|
            if a["applied"]
              puts "  [applied] [#{a['kind']}] #{a['note']} (auto_apply ON)"
            else
              puts "  #{a['approval']}  [#{a['kind']}] #{a['note']}  (dream: #{a['dream_path']})"
            end
          end
        end
        puts "artifact: #{artifact}"
        unless report["approvals"].any? { |a| a["applied"] }
          first = report["approvals"].find { |a| a["approval"] }
          puts "nothing was applied. Approve with: claw work decide #{first['approval']} granted" if first
        end
      end

      def say(msg, quiet) = (quiet ? nil : puts(msg))
    end
  end
end
