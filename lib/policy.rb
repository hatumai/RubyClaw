# frozen_string_literal: true
# The autonomy policy: what the harness may do on its own.
#
#   ACTION -> POLICY -> auto | ask | block | human_only
#
# The decision is made in the tool dispatch path (lib/registry.rb `call`), before the
# tool runs. The four answers mean:
#
#   auto        run it now, no person involved
#   ask         do NOT run it. Park an approval in the work store and answer the model
#               with what it is waiting on, so the model knows it is held rather than
#               broken. A person's grant lets the same action run exactly once.
#   block       refuse; no approval can grant it
#   human_only  refuse; the agent is never the actor, a person does it outside the
#               harness. No approval can grant it either.
#
# DEFAULT-DENY, and it is the whole point: an action that matches no rule is `ask`,
# never `auto`. A rule the operator did not write must not grant autonomy, so leaving
# the harness unattended stays defensible. A missing, empty or unreadable policy file
# lands on the same default -- it fails closed. Every decision is one line in the work
# event log (data/events.jsonl), so what ran unattended, and what a person authorised,
# is reconstructable after the fact.
#
# Matching is by action NAME only: first matching rule wins, `*` is a glob
# (`files.*` matches `files.read` and `files.delete`). The policy never inspects the
# tool's arguments, because it cannot know what a write or a command contains; where
# the line matters (an HTTP read vs a send) the harness names two actions instead.
# See REVIEW.md for what that leaves open.
require "yaml"
require "time"
require "fileutils"
require_relative "work"

module RubyClaw
  module Policy
    DEFAULT_FILE = File.join(ROOT, "policy.yml")
    # The instance layer, layered exactly the way instance/SOUL.md beats SOUL.md: a copy
    # at ROOT/instance/policy.yml wins over both the shipped file and CLAW_POLICY. It
    # exists because policy.yml ships with the project and is tracked by git: a change
    # written there would collide with the next `git pull`. A chat command writes HERE
    # instead, so the operator's own policy is theirs and upstream's file stays upstream's.
    INSTANCE_FILE = File.join(ROOT, "instance", "policy.yml")
    POLICIES = %w[auto ask block human_only].freeze
    DEFAULT_POLICY = "ask"

    # tool name -> namespaced action name. Explicit, in one place, and tested, because
    # the policy is only as honest as this mapping: the rule file matches on the action
    # name, never on the tool's prose description. A tool nobody listed here gets
    # `tool.<name>` -- and, with no rule to cover it, default-deny make that `ask`.
    TOOL_ACTIONS = {
      "sh" => "shell.run",
      "term" => "shell.run",
      "read_file" => "files.read",
      "write_file" => "files.write",
      "grep" => "files.search",
      "http" => "http.get",           # refined by method, below
      "remember" => "notes.write",
      "browser" => "browser.drive",
      "schedule" => "schedule.manage",
      "extend" => "selfwrite.tool",   # refined by kind, below
      "work" => "work.manage",        # refined by action, below
      "responsibility" => "responsibility.manage",
      # Scout is the one tool pair whose name IS its read-only guarantee: both actions are
      # reads, the code issues GET and refuses every other verb before a socket opens, and
      # there is deliberately no `scout.send` or `scout.write` name for a rule to reach.
      "scout_search" => "scout.search",
      "scout_read" => "scout.read",
      # The harness's own outbound Telegram. It is not a tool the model calls; naming it
      # here lets policy.yml say, explicitly, that this channel is `auto`. An approval
      # system whose own notification channel could be parked would deadlock: the message
      # carrying the Approve button would itself be waiting for a person.
      "telegram" => "telegram.send"
    }.freeze

    # The refinement tables. They read ONE coarse argument and never its content: an
    # http POST can carry a credential in its body and this name cannot see that, which
    # is exactly the limitation REVIEW.md records.
    HTTP_READ_METHODS = %w[GET HEAD].freeze
    SELFWRITE_KINDS = %w[tool skill core].freeze

    class << self
      # ---- the tool -> action mapping ---------------------------------------

      def action_for(tool, args = nil)
        name = tool.to_s
        base = TOOL_ACTIONS.fetch(name, "tool.#{name}")
        case name
        when "http"   then refine_http(base, args)
        when "extend" then refine_extend(base, args)
        when "work"   then refine_work(base, args)
        else base
        end
      end

      def refine_http(base, args)
        m = arg(args, "method").to_s.upcase
        m.empty? || HTTP_READ_METHODS.include?(m) ? base : "http.send"
      end

      def refine_extend(base, args)
        k = arg(args, "kind").to_s.downcase
        SELFWRITE_KINDS.include?(k) ? "selfwrite.#{k}" : base
      end

      # The agent must never decide its own approvals -- a self-granted approval would
      # make the whole layer a formality -- so `work.decide` is its own action name.
      def refine_work(base, args)
        arg(args, "action").to_s.downcase == "decide" ? "work.decide" : base
      end

      def arg(args, key)
        return nil unless args.is_a?(Hash)

        args[key] || args[key.to_sym]
      end

      # ---- reading the policy file ------------------------------------------

      # ROOT/instance/policy.yml wins when present, then CLAW_POLICY if set, then the
      # shipped ROOT/policy.yml. The layering is by replacement, not merge -- the file
      # that wins is the whole policy, the same way instance/SOUL.md replaces the soul.
      def path
        return INSTANCE_FILE if File.exist?(INSTANCE_FILE)

        p = ENV["CLAW_POLICY"].to_s
        p.empty? ? DEFAULT_FILE : File.expand_path(p)
      end

      def instance_path = INSTANCE_FILE
      def from_instance? = path == INSTANCE_FILE

      # Write the instance layer with `name` as the default, keeping the rules already
      # in force so setting a default cannot silently drop them. The shipped file is
      # never touched. reset! so the change is live on the next check, no restart.
      # An unknown name is refused with the four valid ones listed.
      def set_default!(name)
        name = name.to_s.strip.downcase
        unless POLICIES.include?(name)
          raise Error, "unknown policy #{name.inspect}; use #{POLICIES.join(' | ')}"
        end

        rules = (config["rules"] || []).map do |r|
          rule = { "match" => r["match"], "policy" => r["policy"] }
          rule["note"] = r["note"] if r["note"]
          rule
        end
        FileUtils.mkdir_p(File.dirname(INSTANCE_FILE))
        File.write(INSTANCE_FILE, YAML.dump("default" => name, "rules" => rules))
        reset!
        INSTANCE_FILE
      end

      def config
        file = path
        stamp = File.exist?(file) ? "#{File.mtime(file).to_f}-#{File.size(file)}" : "missing"
        @configs ||= {}
        key = [file, stamp]
        @configs[key] ||= begin
          @configs.clear if @configs.size > 16
          load_config(file)
        end
      end

      # For a test (or a long-lived process) that rewrote the file in place.
      def reset!
        @configs = {}
      end

      def load_config(file)
        return { "default" => DEFAULT_POLICY, "rules" => [], "path" => file, "missing" => true } unless File.exist?(file)

        data = begin
          YAML.safe_load(File.read(file)) || {}
        rescue Psych::SyntaxError => e
          raise Error, "#{file} is not valid YAML (#{e.message}); fix or delete it"
        end
        raise Error, "#{file} must be a mapping with `default:` and `rules:`" unless data.is_a?(Hash)

        default = (data["default"] || DEFAULT_POLICY).to_s.strip
        check_policy!(default, file)
        rules = data["rules"] || []
        raise Error, "#{file}: rules must be a list" unless rules.is_a?(Array)

        { "default" => default, "rules" => rules.each_with_index.map { |r, i| parse_rule(r, i, file) },
          "path" => file }
      end

      def parse_rule(rule, index, file)
        raise Error, "#{file}: rule #{index + 1} must be a mapping with `match:` and `policy:`" unless rule.is_a?(Hash)

        matches = Array(rule["match"]).map { |m| m.to_s.strip }.reject(&:empty?)
        raise Error, "#{file}: rule #{index + 1} needs a non-empty `match:`" if matches.empty?

        policy = rule["policy"].to_s.strip
        check_policy!(policy, file)
        note = rule["note"].to_s.strip
        { "match" => matches, "policy" => policy, "note" => (note.empty? ? nil : note) }
      end

      def check_policy!(policy, file)
        return if POLICIES.include?(policy)

        raise Error, "#{file}: unknown policy #{policy.inspect}; use #{POLICIES.join(' | ')}"
      end

      # ---- the decision (pure) ----------------------------------------------

      # The rule that decides an action, and why. Pure, so the whole matrix can be
      # exercised without a process or a store.
      def decide(action, cfg = nil)
        cfg ||= config
        name = action.to_s
        rule = cfg["rules"].find { |r| r["match"].any? { |pat| match?(pat, name) } }
        {
          "action" => name,
          "policy" => rule ? rule["policy"] : cfg["default"],
          "matched" => rule && rule["match"],
          "note" => rule && rule["note"],
          "source" => rule ? "rule" : "default"
        }
      end

      def match?(pattern, name)
        File.fnmatch(pattern, name)
      rescue StandardError
        false # an unreadable pattern in a hand-edited file must not become "allow"
      end

      # ---- the gate the dispatch path calls ---------------------------------

      # Returns {"run" => true, ...} when the action may run, or {"run" => false,
      # "policy" =>, "message" =>} when it may not. Everything it decides is recorded
      # in the work event log.
      def check(tool, args = nil)
        action = action_for(tool, args)
        d = decide(action)
        case d["policy"]
        when "auto"
          # Only a rule-driven `auto` is an "auto-approval" worth recording; a policy
          # whose `default` is itself `auto` has opted out of supervising at all.
          audit("policy.auto", tool, action, d) if d["source"] == "rule"
          { "run" => true, "action" => action, "policy" => "auto" }
        when "ask"
          allow_on_grant(tool, action, d)
        else
          audit("policy.#{d['policy']}", tool, action, d)
          { "run" => false, "action" => action, "policy" => d["policy"],
            "message" => refusal_message(action, d) }
        end
      end

      # A granted approval authorises its action ONCE. Taking it is atomic (Work does it
      # under the store lock), so two identical calls at the same instant cannot both ride
      # the same grant -- the second finds nothing and asks again.
      def allow_on_grant(tool, action, d)
        grant = Work.take_grant(action, note: "used by #{tool}")
        if grant
          audit("policy.granted", tool, action, d, "approval_id" => grant["id"])
          return { "run" => true, "action" => action, "policy" => "granted", "approval" => grant["id"] }
        end

        approval = pending_for(action) || park(action, tool, d)
        audit("policy.ask", tool, action, d, "approval_id" => approval["id"])
        { "run" => false, "action" => action, "policy" => "ask", "approval" => approval["id"],
          "message" => waiting_message(action, approval, d) }
      end

      # One open request per action: a model that retries while it is already waiting is
      # pointed at the request already in the store, not handed a second one.
      def pending_for(action)
        Work.pending_approvals.find { |a| a["action"] == action }
      end

      # An approval must be tied to a task (stage A's rule: a link to nothing is worse
      # than no link), so a held action opens a small task to carry it. Stage C's
      # responsibilities will supply the real task instead.
      def park(action, tool, d)
        task = Work.add_task(title: "approval: #{action}", project: "policy",
                             detail: "#{tool} was held by the autonomy policy (#{why_text(d)})")
        Work.request_approval(task_id: task["id"], action: action, note: why_text(d))
      end

      # One line per decision in the work log, so what ran unattended is reconstructable. Skipped
      # during a selftest: `claw selftest` makes a real tool call from the real tree to prove the
      # surface reaches the world, and that call must not write the project's own durable store --
      # the same rule SelfWrite.propose and Update keep for their own records (CLAW_SELFTEST).
      def audit(kind, tool, action, d, extra = {})
        return if ENV["CLAW_SELFTEST"]

        Work.record({ "kind" => kind, "tool" => tool.to_s, "action" => action,
                      "policy" => d && d["policy"],
                      "rule" => d && Array(d["matched"]).join(", ") }.compact.merge(extra))
      end

      # ---- the words a person (and the model) reads -------------------------

      def why_text(d)
        return "no rule matched, and the policy default-denies" if d["matched"].nil?

        patterns = Array(d["matched"]).map { |m| "`#{m}`" }.join(" or ")
        d["note"] ? "rule #{patterns}: #{d['note']}" : "rule #{patterns}"
      end

      def waiting_message(action, approval, d)
        "WAITING ON A HUMAN: `#{action}` is `ask` (#{why_text(d)}). It did NOT run. " \
          "Approval #{approval['id']} is parked in the work store against task #{approval['task_id']}; " \
          "a person grants it with `claw work decide #{approval['id']} granted`, and the same call " \
          "then runs once. Do not retry expecting it to work in the meantime."
      end

      def refusal_message(action, d)
        if d["policy"] == "human_only"
          "HUMAN ONLY: `#{action}` (#{why_text(d)}) is never done by the agent -- a person must do it " \
            "outside the harness. It did NOT run, and no approval can grant it."
        else
          "BLOCKED BY POLICY: `#{action}` (#{why_text(d)}) is `block`. It did NOT run, and no approval " \
            "can grant it."
        end
      end
    end
  end
end
