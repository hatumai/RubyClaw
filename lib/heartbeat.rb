# frozen_string_literal: true
# The heartbeat: one pass that moves unattended work forward.
#
# It runs from the scheduler (`claw up`, `claw schedd`) or on its own (`claw heartbeat`).
# A pass does five things, in order:
#
#   1. poll the trigger sources the harness can see for itself -- a responsibility's due
#      timer, a tracked file that changed, a scout query that is due -- and submit them as
#      events;
#   2. scan the event log for internal transitions (a task moved, a scheduled job
#      finished) since the last pass, and submit those too;
#   3. drain the inbox: every pending event is matched to a responsibility (or ignored),
#      and a match creates exactly one durable task under it;
#   4. survey open tasks: a WAITING or BLOCKED task whose dependency is satisfied resumes,
#      a stuck one whose retry is due is retried a bounded number of times, and a task
#      past its deadline parks an approval;
#   5. report what it did.
#
# **Most passes make no model call at all.** Nothing here constructs a harness, sends a
# prompt or reads a model: the pass is store work and clock work. Deciding to *do* the
# work a task represents is a separate, later act -- the heartbeat never runs a task's
# model. A pass with nothing to do is five reads and a "no".
require "time"
require_relative "work"
require_relative "event"
require_relative "responsibility"
require_relative "notify"
require_relative "scout"

module RubyClaw
  module Heartbeat
    class << self
      # The heartbeat's own state is the stores it reads; it holds no lock of its own
      # beyond the per-operation flock every Work write already takes. Two heartbeats at
      # once therefore cannot corrupt a store or double a task (see REVIEW.md), but they
      # may both do the same harmless read.
      #
      # Step 6 is stage D: what the pass *did* is routed to a person (lib/notify.rb),
      # respecting the reporting policy and the bot's allowlist. It is last on purpose --
      # by then the approvals and state moves this pass made are already in the event log
      # the notification scan reads, so a hold parked seconds ago is announced in the
      # same pass rather than the next one.
      def pass(now: Time.now)
        report = { "at" => now.utc.iso8601, "model_calls" => 0, "events" => {},
                   "resumed" => [], "retried" => [], "failed" => [], "approvals" => [],
                   "submitted" => 0, "scanned" => 0, "notify" => {} }
        report["scanned"] = Event.scan_log(now: now)
        report["submitted"] = poll_triggers(now)
        report["events"] = Event.process(now: now)
        survey(now, report)
        report["notify"] = notify(now)
        record_pass(report)
        report
      end

      # Notifications must not be able to stop the work. A corrupt notification store is
      # reported where a person will see it (the pass render, `claw status`) rather than
      # raised into the scheduler's tick.
      def notify(now)
        Notify.run(now: now)
      rescue StandardError => e
        { "error" => "#{e.class}: #{e.message}" }
      end

      # Keep the last pass beside the other stores so `claw status` can report the
      # harness's own health without running one. A summary, not the whole report.
      def record_pass(report)
        n = report["notify"] || {}
        Work.save_heartbeat_state(
          "at" => report["at"], "model_calls" => report["model_calls"],
          "scanned" => report["scanned"], "submitted" => report["submitted"],
          "created" => report.dig("events", "created").to_i,
          "processed" => report.dig("events", "processed").to_i,
          "resumed" => report["resumed"].size, "retried" => report["retried"].size,
          "failed" => report["failed"].size, "approvals" => report["approvals"].size,
          "enqueued" => n["enqueued"].to_i, "sent" => n["sent"].to_i,
          "suppressed" => n["suppressed"].to_i, "digest" => n["digest"].to_i,
          "no_destination" => n["no_destination"].to_i, "queued" => n["queued"].to_i,
          "notify_error" => n["error"]
        )
      rescue StandardError
        nil      # the pass happened; failing to write its own record must not undo that
      end

      # The last pass, or {} when none has been recorded on this machine yet.
      def last_pass = Work.heartbeat_state

      # Claim-before-submit, as the scheduler does: the timer's next slot is advanced when
      # it is claimed, so a slot fires once.
      # The heartbeat polls this alongside the timers and the file watchers: a scout trigger
      # is one more source the harness can see for itself.
      def poll_triggers(now)
        fired = Responsibility.claim_timers(now: now) + Responsibility.poll_files + Scout.poll_triggers(now: now)
        fired.count { |attrs| !Event.submit_attrs(attrs, now: now)["duplicate"] }
      end

      def survey(now, report)
        Work.tasks.each do |task|
          next if %w[DONE FAILED NEEDS_APPROVAL].include?(task["state"])

          act_on(task, now, report)
        end
      end

      def act_on(task, now, report)
        dep = task["depends_on"].to_s.strip
        return survey_dependency(task, now, report, dep) unless dep.empty?
        return resume(task, now, report, "resume_at passed") if due?(task["resume_at"], now)
        if %w[WAITING BLOCKED].include?(task["state"]) && due?(task["retry_at"], now)
          return retry_task(task, now, report)
        end
        return unless overdue?(task, now)

        park(task, now, report, "task is past its deadline: #{task['title']}")
      end

      # A dependency that finished resumes the task; one that failed needs a person --
      # the heartbeat cannot resolve it, so it parks an approval rather than guessing.
      # A dependency that names no task yet is left alone: the other task may still arrive.
      def survey_dependency(task, now, report, dep)
        other = Work.find_task(dep)
        return unless other

        case other["state"]
        when "DONE"   then resume(task, now, report, "dependency #{dep} is DONE")
        when "FAILED" then park(task, now, report, "dependency #{dep} FAILED")
        end
      end

      def resume(task, now, report, why)
        Work.set_state(task["id"], "WORKING", note: why, now: now)
        report["resumed"] << task["id"]
      end

      def retry_task(task, now, report)
        updated = Work.record_retry(task["id"], note: "heartbeat retry", now: now)
        (updated["state"] == "FAILED" ? report["failed"] : report["retried"]) << task["id"]
      end

      def park(task, now, report, why)
        return if Work.pending_approvals.any? { |a| a["task_id"] == task["id"] }

        Work.request_approval(task_id: task["id"], action: why, note: "heartbeat: #{why}", now: now)
        report["approvals"] << task["id"]
      end

      def due?(stamp, now)
        return false if stamp.to_s.strip.empty?

        Time.parse(stamp.to_s) <= now
      rescue StandardError
        false
      end

      def overdue?(task, now) = due?(task["deadline"], now)

      def render(report)
        e = report["events"] || {}
        n = report["notify"] || {}
        empty = ->(v) { v.nil? || v.empty? ? "—" : v.join(", ") }
        ["heartbeat #{report['at']}",
         "  events:  #{e['processed'].to_i} processed, #{e['created'].to_i} created task(s), " \
         "#{e['ignored'].to_i} ignored, #{e['duplicates'].to_i} already had a task",
         "  resumed: #{empty.call(report['resumed'])}",
         "  retried: #{empty.call(report['retried'])}",
         "  failed:  #{empty.call(report['failed'])}",
         "  parked on a person: #{empty.call(report['approvals'])}",
         "  told a person: #{notify_line(n)}",
         "  model calls: #{report['model_calls']}"].join("\n") + "\n"
      end

      def notify_line(n)
        return "FAILED — #{n['error']}" if n["error"]

        line = "sent #{n['sent'].to_i}, queued #{n['queued'].to_i}, suppressed #{n['suppressed'].to_i}, " \
               "held for digest #{n['digest'].to_i}, no destination #{n['no_destination'].to_i}"
        line += ", DROPPED #{n['dropped'].to_i} (queue full)" if n["dropped"].to_i.positive?
        line
      end
    end
  end
end
