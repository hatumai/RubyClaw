# frozen_string_literal: true
# One shape for every trigger, so the heartbeat has one thing to drain.
#
#   timer | file.changed | work.state | job.finished | webhook
#
# A source turns a happening into an event and calls `submit`; the event goes into a
# durable inbox (data/pending-events.json) and is matched to a responsibility on the next
# drain. A match creates exactly one durable task under that responsibility (see
# Work.add_task_once); no match is recorded and ignored. The responsibility is the
# commitment, the task is one piece of work toward it.
#
# Idempotence is the property this file exists to keep: the same event never creates a
# second task. Two layers enforce it, and the second is the binding one --
#
#   * the inbox ledger skips re-queueing an event whose key is already pending or handled;
#   * the created task carries the event's key (task["event_key"]), and add_task_once
#     refuses to make a second task for a key that already has one. That check and the
#     create share one critical section, so two processes replaying the same event at the
#     same instant cannot both create a task. This holds even after the ledger forgets the
#     key (it is capped), because the task remembers.
#
# Which sources this actually has: timers and file changes (polled by
# lib/heartbeat.rb from a responsibility's triggers), a read-only Scout query (also polled by
# the heartbeat; lib/scout.rb does the search and fingerprints each page so one page is one
# event), internal transitions and job finishes (scanned out of data/events.jsonl, which every
# store change already writes), and a webhook as a *submission seam* -- `claw event post` or the
# responsibility tool -- not as a listening socket. The analysis's email/calendar/GitHub/
# regulatory feeds do not exist here and are not claimed; Scout is a keyless web search plus a
# one-URL read (lib/scout.rb), not that inbox.
require "json"
require "digest"
require "time"
require_relative "work"
require_relative "responsibility"

module RubyClaw
  module Event
    TYPES = %w[timer file.changed work.state job.finished webhook scout].freeze

    class << self
      # ---- the key: what makes an event the same event ---------------------

      # Deterministic in the source's identifying facts, so replaying a happening
      # produces the same key and therefore the same single task. A timer keys on the
      # slot it fired for (each slot is one event; the same slot replayed is not); a file
      # on the fingerprint it changed to; a state move on the task, the move and when; a
      # job on the job and the run; a webhook on the caller's idempotency key, or the
      # body's digest when the caller gives none; a Scout finding on the trigger and the
      # page it points at, so one page is one event.
      def build_key(type, payload)
        p = payload || {}
        case type.to_s
        when "timer"        then "timer:#{p['trigger_id']}:#{p['slot']}"
        when "file.changed" then "file.changed:#{p['trigger_id']}:#{p['fingerprint']}"
        when "work.state"   then "work.state:#{p['task_id']}:#{p['from']}->#{p['to']}:#{p['ts']}"
        when "job.finished" then "job.finished:#{p['name']}:#{p['ts']}"
        when "scout"
          # One trigger, one page: the same URL found again is the same event, so it does
          # not become a second task however many polls it survives (see lib/scout.rb).
          "scout:#{p['trigger_id']}:#{p['fingerprint']}"
        when "webhook"
          explicit = p["key"].to_s.strip
          explicit.empty? ? "webhook:#{p['source']}:#{digest(p)}" : "webhook:#{p['source']}:#{explicit}"
        else
          raise Error, "unknown event type #{type.inspect}; use #{TYPES.join(', ')}"
        end
      end

      def digest(payload)
        Digest::SHA256.hexdigest(JSON.generate(payload || {}))[0, 16]
      end

      # ---- submitting ------------------------------------------------------

      # Put an event in the inbox. An explicit `key:` is the event's key, used as given (the
      # caller vouches for its uniqueness); with none, the key is derived from the type and
      # payload by build_key. Returns the event with "duplicate" true when its key is already
      # pending or handled -- the caller may have replayed it, and it is not queued twice.
      def submit(type:, payload: {}, source: nil, key: nil, now: Time.now)
        type = type.to_s
        raise Error, "unknown event type #{type.inspect}; use #{TYPES.join(', ')}" unless TYPES.include?(type)

        final_key = key.to_s.strip
        final_key = build_key(type, payload || {}) if final_key.empty?
        raise Error, "an event needs a key" if final_key.empty?

        event = { "id" => Work.new_id("ev"), "type" => type, "key" => final_key,
                  "source" => Work.blank_to_nil(source), "payload" => payload || {},
                  "ts" => now.utc.iso8601 }
        duplicate = false
        Work.with_lock do
          store = Work.inbox_store
          if store["handled"].include?(final_key) || store["events"].any? { |e| e["key"] == final_key }
            duplicate = true
          else
            store["events"] << event
            Work.save_inbox(store)
          end
        end
        event.merge("duplicate" => duplicate)
      end

      def submit_attrs(attrs, now: Time.now)
        submit(type: attrs["type"], payload: attrs["payload"] || {}, source: attrs["source"],
               key: attrs["key"], now: now)
      end

      def pending = Work.pending_events
      def handled?(key) = Work.inbox_store["handled"].include?(key.to_s)

      # ---- draining --------------------------------------------------------

      # Match every pending event to a responsibility and, on a match, create exactly one
      # task. The inbox is snapshotted first and each event marked handled after it is
      # processed, in separate critical sections: two heartbeats may look at the same
      # event at once, but add_task_once makes the task once and mark_handled is
      # idempotent, so the outcome is the same either way.
      def process(now: Time.now)
        report = { "processed" => 0, "created" => 0, "ignored" => 0, "duplicates" => 0, "tasks" => [] }
        seen = {}
        pending.each do |event|
          key = event["key"].to_s
          next if seen[key]

          seen[key] = true
          matched = Responsibility.match(event)
          if matched.nil?
            Work.record({ "kind" => "event.ignored", "event_id" => event["id"], "event" => event["type"],
                          "key" => key })
            report["ignored"] += 1
          else
            created = create_task(event, matched, now)
            report[created ? "created" : "duplicates"] += 1
            report["tasks"] << event["key"] if created
          end
          mark_handled(key)
          report["processed"] += 1
        end
        report
      end

      def create_task(event, matched, now)
        resp, trigger = matched
        detail = "from responsibility #{resp['id']} via #{Responsibility.describe_trigger(trigger)}"
        finding = finding_line(event["payload"])
        detail = "#{detail}\n#{finding}" if finding
        task, created = Work.add_task_once(
          title: resp["objective"], event_key: event["key"], project: resp["project"],
          owner: resp["owner"], skill: resp["skill"], responsibility_id: resp["id"],
          detail: detail, now: now
        )
        Work.record({ "kind" => created ? "event.matched" : "event.duplicate",
                      "event_id" => event["id"], "event" => event["type"], "key" => event["key"],
                      "task_id" => task["id"], "responsibility_id" => resp["id"],
                      "trigger_id" => trigger["id"] })
        created
      end

      # A Scout finding is not just "the trigger fired": the task carries what was found,
      # so `claw work show` (and a notification's task line) names the page instead of only
      # the responsibility's objective. Anything without a URL -- every other event type --
      # adds nothing.
      def finding_line(payload)
        return nil unless payload.is_a?(Hash)

        url = payload["url"].to_s.strip
        return nil if url.empty?

        title = payload["title"].to_s.strip
        "found: #{title.empty? ? '(untitled)' : title}\nurl: #{url}"
      end

      def mark_handled(key)
        key = key.to_s
        Work.with_lock do
          store = Work.inbox_store
          store["events"].reject! { |e| e["key"].to_s == key }
          unless store["handled"].include?(key)
            store["handled"] << key
            store["handled"] = store["handled"].last(Work::HANDLED_MAX)
          end
          Work.save_inbox(store)
        end
      end

      # ---- scanning the harness's own transitions --------------------------
      #
      # work.state and job.finished are not submitted by their writers (that would make
      # lib/work.rb depend on this file); they are read back out of the event log every
      # change already writes. The scan remembers its position by raw line number.
      #
      # A task that was itself created by an event does not generate a work.state event:
      # a responsibility watching for DONE that also produced the task would otherwise
      # create a new task every time one finished, forever. Breaking the chain at the
      # responsibility's own tasks is the deliberate limit (see REVIEW.md).
      def scan_log(now: Time.now)
        lines = Work.event_log_raw
        offset = (Work.inbox_store["scan"]["log"] || 0).to_i
        offset = 0 if offset.negative? || offset > lines.size
        submitted = 0
        lines[offset..].to_a.each do |line|
          parsed = parse_line(line)
          next unless parsed

          attrs = scan_attrs(parsed)
          next unless attrs

          submitted += 1 unless submit_attrs(attrs, now: now)["duplicate"]
        end
        advance_scan(lines.size)
        submitted
      end

      def scan_attrs(entry)
        case entry["kind"]
        when "task.state"
          task = Work.find_task(entry["task_id"])
          return nil if task.nil? || task["event_key"]

          { "type" => "work.state",
            "payload" => { "task_id" => entry["task_id"], "from" => entry["from"], "to" => entry["to"],
                           "ts" => entry["ts"], "project" => task["project"] } }
        when "job.finished"
          { "type" => "job.finished",
            "payload" => { "name" => entry["name"], "ts" => entry["ts"], "ok" => entry["ok"] } }
        end
      end

      def advance_scan(count)
        Work.with_lock do
          store = Work.inbox_store
          store["scan"] = (store["scan"] || {}).merge("log" => count)
          Work.save_inbox(store)
        end
      end

      def parse_line(line)
        entry = JSON.parse(line)
        entry.is_a?(Hash) ? entry : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
