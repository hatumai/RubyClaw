# frozen_string_literal: true
# Standing commitments, and the triggers that start work toward them.
#
# A task is one piece of work; a responsibility is the thing that keeps asking for work.
# It has an objective that stays true ("keep the deploy notes current"), an owner, a
# project, a skill or workflow to run, an autonomy level and a reporting policy -- and
# one or more triggers. Each time a trigger fires, exactly one task is created under the
# responsibility (see lib/event.rb); the responsibility itself never runs.
#
# The record lives beside the work store (data/responsibilities.json, the same lock and
# atomic write as every other store in lib/work.rb). This module is the logic on top of
# it: validating and parsing trigger specs, matching a normalised event to a
# responsibility, and polling the two sources the harness can see for itself -- a timer,
# and a file whose contents changed. The rest of the gap analysis's list (email, calendar,
# GitHub, regulatory feeds) is stage E; this file does not pretend to those.
#
#   trigger          fires when
#   timer every 15m  the clock passes the trigger's next slot (Schedule's date maths)
#   file.changed P    a tracked file's size/mtime fingerprint differs from the stored one
#   work.state S     a task moves to state S (and, if given, project=)
#   job.finished N   a scheduled job called N finishes
#   webhook src      an event is submitted with source=src (a seam, not a listener)
#   scout QUERY      a read-only web search for QUERY returns a page not seen before
#                    (every `every` interval, default 6h; lib/scout.rb does the polling)
require "time"
require_relative "work"
require_relative "schedule"

module RubyClaw
  module Responsibility
    TRIGGER_TYPES = %w[timer file.changed work.state job.finished webhook scout].freeze
    # How often a `scout` trigger polls the web by default. Owned here, with the rest of the
    # trigger vocabulary; lib/scout.rb (which does the polling) reads it from here.
    SCOUT_EVERY = "every 6h".freeze
    AUTONOMY = %w[auto ask].freeze
    # The reporting policy: when the harness tells a person about this responsibility's
    # work. Enforced where a responsibility is created (here) and where a message would be
    # sent (lib/notify.rb routes on it). The first three are the original names; `always`
    # and `silent` are synonyms of `on_change` and `never`, kept so a policy file or a
    # person can write the word they mean. See lib/notify.rb for what each admits.
    REPORTING = %w[on_change on_completion on_failure always daily_digest silent never].freeze

    class << self
      # ---- creating -------------------------------------------------------

      # Add a responsibility. Triggers may be strings (`"timer every 15m"`) or hashes;
      # each gets an id, an enabled flag and, for a timer, its first slot -- due now, the
      # way `Schedule.add` is, so a commitment proves itself on the next heartbeat instead
      # of waiting a day to be noticed. Everything here is validated before anything is
      # written, so a bad spec leaves no half-made responsibility behind.
      def add(objective:, owner: nil, project: nil, triggers: [], skill: nil, autonomy: "ask",
              reporting: "on_completion", enabled: true, now: Time.now)
        autonomy = autonomy.to_s.strip
        raise Error, "autonomy is #{AUTONOMY.join(' or ')} (got #{autonomy.inspect})" unless AUTONOMY.include?(autonomy)

        reporting = reporting.to_s.strip
        unless REPORTING.include?(reporting)
          raise Error, "reporting is #{REPORTING.join(', ')} (got #{reporting.inspect})"
        end

        built = Array(triggers).map { |t| build_trigger(t, now: now) }
        raise Error, "a responsibility needs at least one trigger, or nothing will ever start it" if built.empty?

        Work.add_responsibility(
          { "objective" => objective, "owner" => owner, "project" => project, "skill" => skill,
            "autonomy" => autonomy, "reporting" => reporting, "enabled" => enabled,
            "triggers" => built }, now: now
        )
      end

      def build_trigger(trigger, now: Time.now)
        t = trigger.is_a?(Hash) ? stringify(trigger) : parse_trigger(trigger)
        type = t["type"].to_s
        unless TRIGGER_TYPES.include?(type)
          raise Error, "unknown trigger type #{type.inspect}; use #{TRIGGER_TYPES.join(', ')}"
        end

        out = { "id" => Work.new_id("tr"), "type" => type, "enabled" => t.fetch("enabled", true) ? true : false }
        case type
        when "timer"
          spec = t["spec"].to_s.strip
          Schedule.parse_spec(spec)          # raises with the accepted forms if it cannot read it
          out["spec"] = spec
          out["next_run"] = (now + 0.001).utc.iso8601 if out["enabled"]
        when "file.changed"
          path = t["path"].to_s.strip
          raise Error, "a file.changed trigger needs a path" if path.empty?

          out["path"] = path
          # No fingerprint key yet: the first poll records a baseline and does NOT fire,
          # so adding a trigger over an existing file does not fire immediately.
        when "work.state"
          to = Work.normalize_state(t["to"])
          out["to"] = to
          out["project"] = Work.blank_to_nil(t["project"])
        when "job.finished"
          name = t["name"].to_s.strip
          raise Error, "a job.finished trigger needs the job's name" if name.empty?

          out["name"] = name
        when "webhook"
          source = t["source"].to_s.strip
          raise Error, "a webhook trigger needs a source name" if source.empty?

          out["source"] = source
        when "scout"
          query = t["query"].to_s.strip
          raise Error, "a scout trigger needs a search query, e.g. scout \"ruby 3.5 release notes\"" if query.empty?

          out["query"] = query
          every = t["every"].to_s.strip
          every = SCOUT_EVERY if every.empty?
          Schedule.parse_spec(every)     # raises with the accepted forms if it cannot read it
          out["every"] = every
          # Due now, like a timer: a new commitment proves itself on the next heartbeat
          # instead of waiting six hours to be noticed.
          out["next_run"] = (now + 0.001).utc.iso8601 if out["enabled"]
        end
        out
      end

      # "timer every 15m" | "file.changed /abs/path" | "work.state DONE project=ops" |
      # "job.finished nightly" | "webhook github-push" | "scout ruby 3.5 release notes"
      def parse_trigger(str)
        type, rest = str.to_s.strip.split(/\s+/, 2)
        rest = rest.to_s.strip
        case type
        when "timer"         then { "type" => "timer", "spec" => rest }
        when "file.changed"  then { "type" => "file.changed", "path" => rest }
        when "job.finished"  then { "type" => "job.finished", "name" => rest }
        when "webhook"       then { "type" => "webhook", "source" => rest }
        when "scout"         then { "type" => "scout", "query" => rest }
        when "work.state"
          to, *opts = rest.split(/\s+/)
          t = { "type" => "work.state", "to" => to }
          opts.each { |o| t["project"] = Regexp.last_match(1) if o =~ /\Aproject=(.+)\z/ }
          t
        else
          raise Error, "cannot read trigger #{str.to_s.strip.inspect}. Try \"timer every 15m\", " \
                       "\"file.changed /path\", \"work.state DONE\", \"job.finished <name>\", " \
                       "\"webhook <source>\" or \"scout <search query>\"."
        end
      end

      def stringify(hash) = hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }

      # ---- reading --------------------------------------------------------

      def list = Work.responsibilities
      def find(id) = Work.find_responsibility(id)

      # The first responsibility whose trigger matches the event, plus the trigger. One
      # event matches at most one responsibility, so one event can create at most one task.
      def match(event, responsibilities = nil)
        (responsibilities || list).each do |resp|
          next if resp["enabled"] == false

          (resp["triggers"] || []).each do |tr|
            return [resp, tr] if trigger_matches?(tr, event)
          end
        end
        nil
      end

      def trigger_matches?(trigger, event)
        return false if trigger["enabled"] == false
        return false unless trigger["type"].to_s == event["type"].to_s

        payload = event["payload"] || {}
        case trigger["type"]
        when "timer", "file.changed", "scout"
          payload["trigger_id"] == trigger["id"]
        when "work.state"
          trigger["to"].to_s.upcase == payload["to"].to_s.upcase &&
            (trigger["project"].nil? || trigger["project"] == payload["project"])
        when "job.finished"
          trigger["name"].to_s == payload["name"].to_s
        when "webhook"
          trigger["source"].to_s == payload["source"].to_s
        else
          false
        end
      end

      # ---- polling the two sources the harness can see --------------------

      # Due timers, claimed under the store lock: the fired trigger's next slot is
      # advanced before the event is returned, so two heartbeats at the same instant
      # cannot both fire the same slot (the same claim-before-run discipline as Schedule).
      # Returns a list of event attribute hashes for lib/event.rb to submit.
      def claim_timers(now: Time.now)
        fired = []
        Work.with_lock do
          list = Work.responsibilities
          list.each do |resp|
            next if resp["enabled"] == false

            (resp["triggers"] || []).each do |tr|
              next unless tr["type"] == "timer" && tr["enabled"] != false && tr["next_run"]

              slot = parse_time(tr["next_run"])
              next unless slot && slot <= now

              fired << { "type" => "timer", "responsibility_id" => resp["id"],
                         "payload" => { "trigger_id" => tr["id"], "responsibility_id" => resp["id"],
                                        "slot" => slot.utc.iso8601 } }
              spec = Schedule.parse_spec(tr["spec"])
              tr["next_run"] = Schedule.next_at(spec.merge("name" => resp["id"]), from: [now, Time.now].max)&.utc&.iso8601
            end
          end
          Work.save_responsibilities(list)
        end
        fired
      end

      # Files whose fingerprint changed, recorded under the store lock. The first poll of
      # a trigger records a baseline and does not fire; later polls fire once per change.
      def poll_files
        changed = []
        Work.with_lock do
          list = Work.responsibilities
          list.each do |resp|
            next if resp["enabled"] == false

            (resp["triggers"] || []).each do |tr|
              next unless tr["type"] == "file.changed" && tr["enabled"] != false

              fp = fingerprint(tr["path"])
              if !tr.key?("fingerprint")
                tr["fingerprint"] = fp                 # baseline: do not fire on first sight
              elsif tr["fingerprint"] != fp && !fp.nil?
                tr["fingerprint"] = fp
                changed << { "type" => "file.changed", "responsibility_id" => resp["id"],
                             "payload" => { "trigger_id" => tr["id"], "responsibility_id" => resp["id"],
                                            "path" => tr["path"], "fingerprint" => fp } }
              end
            end
          end
          Work.save_responsibilities(list)
        end
        changed
      end

      # Size and modification time, as one string. Enough to notice a change; not a hash
      # of the contents, which would mean reading every tracked file on every pass.
      def fingerprint(path)
        p = path.to_s
        return nil unless File.file?(p)

        "#{File.size(p)}-#{File.mtime(p).to_i}"
      rescue StandardError
        nil
      end

      def parse_time(str)
        return nil if str.to_s.empty?

        Time.parse(str.to_s)
      rescue StandardError
        nil
      end

      # ---- the view -------------------------------------------------------

      def describe_trigger(tr)
        case tr["type"]
        when "timer"        then "timer #{tr['spec']}"
        when "file.changed" then "file.changed #{tr['path']}"
        when "work.state"   then "work.state #{tr['to']}#{tr['project'] ? " project=#{tr['project']}" : ''}"
        when "job.finished" then "job.finished #{tr['name']}"
        when "webhook"      then "webhook #{tr['source']}"
        when "scout"
          every = tr["every"].to_s.strip.sub(/\Aevery\s+/i, "")
          "scout #{tr['query']}#{every.empty? ? '' : " (every #{every})"}"
        else tr["type"].to_s
        end
      end

      def render
        list = self.list
        out = +"RubyClaw responsibilities — #{list.size} standing commitment(s)\n"
        return out << "\nnothing yet — add one with `claw resp add \"<objective>\" --trigger \"timer every 15m\"`.\n" if list.empty?

        list.each do |r|
          open = Work.tasks_for_responsibility(r["id"]).reject { |t| %w[DONE FAILED].include?(t["state"]) }
          state = r["enabled"] == false ? "paused" : "active"
          out << format("  %-10s %-6s %-14s %s\n", r["id"], state, "#{open.size} open", r["objective"])
          out << "      triggers: #{(r['triggers'] || []).map { |t| describe_trigger(t) }.join('; ')}\n"
          bits = [r["owner"] && "owner #{r['owner']}", r["project"] && "project #{r['project']}",
                  r["skill"] && "skill #{r['skill']}", "autonomy #{r['autonomy']}", "report #{r['reporting']}"]
          out << "      #{bits.compact.join('  ')}\n"
        end
        out
      end
    end
  end
end
