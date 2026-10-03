# frozen_string_literal: true
# Agent-originated notifications: the harness telling a person it needs one.
#
# Everything so far records what happened; this is the part that says so, through the
# delivery path the harness already has (the Telegram adapter and its allowlist). It is
# driven from the heartbeat, so it costs nothing new to install: one pass already exists.
#
# Four rules shape it, and each is a test:
#
#   * Routing. A notification about a responsibility's work respects that
#     responsibility's recorded `reporting` policy instead of being sent regardless.
#     The vocabulary is small and enforced here (see REPORTING and ROUTES).
#   * Destination. Only an allowlisted chat, ever. With no allowlist there is no
#     notification: the message is recorded as undeliverable and nothing is sent.
#     A chat that is not allowlisted is refused, it is never invented.
#   * Dedup. A notification is keyed by the *condition* it is about (an approval id, a
#     task and the state it reached), and a key is recorded once. Two heartbeat passes in
#     a row therefore send one message for one pending approval, and a task retried to
#     failure sends one message, not one per attempt.
#   * Durability. A send that fails is not lost: it stays in data/notifications.json,
#     under the same flock and atomic write as every other store, and the next pass
#     retries it. The outbound TLS to the Bot API times out intermittently on the armv6
#     board, so a lost notification would be the normal case rather than the exception.
#
# With no bot token the module still runs: notifications are queued (bound to the
# allowlisted chat) and drain reports the failure, so nothing crashes and nothing is
# shouted into the void. The queue is the only place a message can wait.
require "json"
require "time"
require "net/http"
require "uri"
require_relative "work"
require_relative "responsibility"
require_relative "telegram"

module RubyClaw
  module Notify
    # The reporting vocabulary, in the order a person reads it. `on_change`, `always`,
    # `silent` and `never` are synonyms kept together so a record written before this
    # stage still means what it said:
    #
    #   on_change / always   every transition of that responsibility's work
    #   on_completion        terminal outcomes (DONE/FAILED) and anything needing a person
    #   on_failure           FAILED/BLOCKED and anything needing a person
    #   daily_digest         no per-event message; the item is recorded for a digest
    #   silent / never       nothing at all for that responsibility
    #
    # One vocabulary, not two: this is `Responsibility::REPORTING`, enforced where a
    # responsibility is created and again below, where a message would actually be sent.
    REPORTING = Responsibility::REPORTING
    DEFAULT_REPORTING = "on_completion"

    # What a routing decision is about. These are the categories a person is told about:
    # a parked approval, a task that finished, failed or was blocked, a scheduled job the
    # policy held, and a digest entry (which is deliberately not a message).
    CONDITIONS = %w[done failed blocked approval held digest].freeze

    MAX_TEXT = 3500          # Telegram's limit is 4096; leave room for the marker
    SEEN_MAX = 1000          # the dedupe ledger, capped like the inbox's handled list
    DIGEST_MAX = 500         # withheld daily_digest entries, capped
    QUEUE_MAX = 500          # undelivered messages; past this the oldest is dropped

    class << self
      # ---- the vocabulary, as data ------------------------------------------

      def canonical(reporting)
        r = reporting.to_s.strip.downcase
        r.empty? ? DEFAULT_REPORTING : r
      end

      def valid_reporting?(reporting) = REPORTING.include?(canonical(reporting))

      # Pure: does this reporting value admit this condition? The whole routing rule, so
      # it can be exercised for every pair without a store or a network.
      def report?(condition, reporting)
        r = canonical(reporting)
        c = condition.to_s
        return false if %w[silent never].include?(r)
        return c == "digest" if r == "daily_digest"
        return true if r == "on_change" || r == "always"
        return %w[failed blocked approval held].include?(c) if r == "on_failure"

        # on_completion, and anything a person hand-edited to nonsense: the default.
        %w[done failed blocked approval held].include?(c)
      end

      # ---- destination ------------------------------------------------------

      # The bot's rule, reused rather than restated: the chats the adapter would answer.
      # Nothing else is a destination, and an empty list means there is none.
      def allowed_chats = Telegram.allowed_chats.map(&:to_i).uniq
      def allowlisted?(chat) = allowed_chats.include?(chat.to_i)

      # ---- one pass: scan the log, route, queue, send -----------------------

      def run(now: Time.now)
        result = scan(now)
        result.merge(drain(now))
      end

      # Read the events the harness already writes (lib/work.rb emits one line per
      # accepted move, approval and hold) and turn the ones that need a person into
      # notifications. The watermark is a line count, like the heartbeat's own scan, and
      # the seen ledger is the binding dedupe: a replayed or hand-copied log line cannot
      # notify twice.
      def scan(now)
        result = { "at" => now.utc.iso8601, "candidates" => 0, "enqueued" => 0, "suppressed" => 0,
                   "digest" => 0, "no_destination" => 0 }
        lines = Work.event_log_raw
        store = Work.notifications_store
        offset = store["scan"].to_i
        offset = 0 if offset.negative? || offset > lines.size
        fresh = lines[offset..].to_a
        return result if fresh.empty?

        seen = (store["seen"] || {}).dup
        chats = allowed_chats
        adds = []
        digest = []
        undeliverable = 0

        fresh.each do |line|
          entry = parse_line(line)
          cand = entry && candidate(entry)
          next unless cand

          result["candidates"] += 1
          key = cand["key"]
          next if seen.key?(key)     # this condition has been said, or decided, already

          seen[key] = now.utc.iso8601
          reporting = reporting_for(cand["responsibility_id"])
          if report?(cand["condition"], reporting)
            if chats.empty?
              undeliverable += 1
              result["no_destination"] += 1
            else
              chats.each { |chat| adds << queued_item(chat, cand, key, now) }
              result["enqueued"] += 1
            end
          elsif canonical(reporting) == "daily_digest"
            digest << { "key" => key, "at" => now.utc.iso8601, "condition" => cand["condition"] }
            result["digest"] += 1
          else
            result["suppressed"] += 1
          end
        end

        result["dropped"] = [store["queue"].size + adds.size - QUEUE_MAX, 0].max
        Work.with_lock do
          s = Work.notifications_store
          s["scan"] = lines.size
          s["seen"] = trim_seen(seen)
          s["digest"] = (s["digest"] + digest).last(DIGEST_MAX)
          s["undeliverable"] = s["undeliverable"].to_i + undeliverable
          s["queue"] = (s["queue"] + adds).last(QUEUE_MAX)
          Work.save_notifications(s)
        end
        result
      end

      # Send what is queued, and keep what will not go. The attempt happens outside the
      # store lock on purpose: holding the one flock across a TLS timeout is how one
      # slow send stalls every other writer on the board this runs on.
      def drain(now)
        result = { "sent" => 0, "failed" => 0, "refused" => 0, "queued" => 0, "error" => nil }
        items = Work.notifications_store["queue"]
        return result if items.empty?

        chats = allowed_chats
        sent_ids = []
        failures = {}
        items.each do |item|
          chat = item["chat"].to_i
          unless chats.include?(chat)
            # Queued while it was allowlisted and no longer is. It can never be delivered
            # legally, so it is refused rather than sent: a person's list is the rule.
            sent_ids << item["id"]
            result["refused"] += 1
            next
          end
          ok, note = attempt(chat, item["text"], item["approval_id"])
          if ok
            sent_ids << item["id"]
            result["sent"] += 1
            record_sent(item)
          else
            failures[item["id"]] = { "attempts" => item["attempts"].to_i + 1,
                                     "last_error" => note, "last_try" => now.utc.iso8601 }
            result["failed"] += 1
            result["error"] ||= note
          end
        end

        Work.with_lock do
          s = Work.notifications_store
          s["queue"].reject! { |i| sent_ids.include?(i["id"]) }
          s["queue"].each { |i| i.merge!(failures[i["id"]]) if failures.key?(i["id"]) }
          Work.save_notifications(s)
          result["queued"] = s["queue"].size
        end
        result
      end

      # ---- a condition the harness raises itself ----------------------------
      #
      # Not every notification comes from the work log. The poll loop telling a person it
      # cannot reach Telegram is one, and it rides the same queue and the same seen-ledger
      # rather than inventing a second path: keying it by the condition and recording the
      # key once is exactly what keeps an outage to one message instead of one per failed
      # poll. `rearm` drops a key once its condition is over, so a *later* outage can be
      # announced again instead of being deduped into silence forever.
      def signal(key, text, now: Time.now)
        chats = allowed_chats
        return false if chats.empty?

        queued = false
        Work.with_lock do
          st = Work.notifications_store
          unless (st["seen"] || {}).key?(key)
            chats.each do |chat|
              st["queue"] = (st["queue"] << queued_item(chat, { "text" => text, "condition" => nil },
                                                        key, now)).last(QUEUE_MAX)
            end
            st["seen"] = trim_seen((st["seen"] || {}).merge(key => now.utc.iso8601))
            Work.save_notifications(st)
            queued = true
          end
        end
        drain(now) if queued
        queued
      end

      # Is the condition keyed by `key` still in force (signalled and not re-armed)? The
      # ledger is the only state, so there is no second flag to drift out of sync with it.
      def signalled?(key) = (Work.notifications_store["seen"] || {}).key?(key)

      def rearm(key)
        Work.with_lock do
          st = Work.notifications_store
          st["seen"] = (st["seen"] || {}).reject { |k, _| k == key }
          Work.save_notifications(st)
        end
      end

      # ---- the one thing that actually sends --------------------------------

      # True, or false and why. A missing token is a failure, not a crash: the harness
      # must run headless, and the message waits for a token that is not there yet.
      # An approval item carries its id, so the message goes with the Approve/Deny
      # keyboard; send_chunks (not send_message) is used because it raises on failure,
      # which is what keeps a lost send in the durable queue for a retry.
      def attempt(chat, text, approval_id = nil)
        tg = Telegram.new
        markup = approval_id.to_s.empty? ? nil : Telegram.approval_keyboard(approval_id)
        tg.send_chunks(chat.to_i, text.to_s[0, MAX_TEXT], reply_markup: markup)
        [true, nil]
      rescue StandardError => e
        [false, "#{e.class}: #{e.message}".split("\n").first.to_s[0, 300]]
      end

      def record_sent(item)
        Work.record({ "kind" => "notify.sent", "notification_id" => item["id"],
                      "chat" => item["chat"], "key" => item["key"] })
      rescue StandardError
        nil
      end

      # ---- the escape hatch -------------------------------------------------

      # `claw notify test`: prove the path end to end. One message, bound to the
      # allowlisted chat(s), drained immediately. An explicit chat must be allowlisted
      # or it is refused; with no allowlist there is no destination and it says so.
      def test_message(chat: nil, now: Time.now)
        chats = allowed_chats
        target = []
        if chat
          c = chat.to_i
          unless chats.include?(c)
            return { "ok" => false, "sent" => 0, "queued" => queue_depth, "target" => [],
                     "error" => "chat #{c} is not in telegram_allowed_chat_ids " \
                                "(#{chats.empty? ? 'none configured' : chats.join(', ')}); refusing to send" }
          end
          target = [c]
        else
          target = chats
        end
        if target.empty?
          return { "ok" => false, "sent" => 0, "queued" => queue_depth, "target" => [],
                   "error" => "no destination configured: set telegram_allowed_chat_ids in config.yml " \
                              "(or CLAW_TELEGRAM_ALLOWED in .env) and restart; nothing was sent" }
        end

        text = "🔔 RubyClaw test notification — delivery works. (#{now.utc.iso8601})"
        key = "test:#{now.to_f}"
        target.each { |c| enqueue(c, text, key, now: now) }
        sent = drain(now)
        { "ok" => sent["sent"].positive?, "sent" => sent["sent"], "queued" => queue_depth,
          "target" => target, "error" => sent["error"] }
      end

      # ---- the queue, for a person ------------------------------------------

      def queue = Work.notifications_store["queue"]
      def queue_depth = queue.size
      def digest_count = (Work.notifications_store["digest"] || []).size
      def undeliverable_count = Work.notifications_store["undeliverable"].to_i
      def seen_count = (Work.notifications_store["seen"] || {}).size

      def enqueue(chat, text, key = nil, now: Time.now)
        item = queued_item(chat, { "text" => text, "condition" => nil }, key, now)
        Work.with_lock do
          s = Work.notifications_store
          s["queue"] = (s["queue"] << item).last(QUEUE_MAX)
          Work.save_notifications(s)
        end
        item
      end

      def render_queue(limit = 10)
        items = queue
        return "notification queue: empty — nothing waiting to be sent\n" if items.empty?

        out = +"notification queue: #{items.size} message(s) waiting\n"
        items.first(limit).each do |i|
          out << format("  %-14s chat %-12s %2d attempt(s)  queued %s  %s\n", i["id"], i["chat"],
                        i["attempts"].to_i, i["queued"], i["last_error"].to_s[0, 70])
        end
        out << "  …and #{items.size - limit} more\n" if items.size > limit
        out << "retry now:  claw notify drain\n"
        out
      end

      def render_drain(result)
        return "notification drain: cannot read the queue (#{result['error']})\n" unless result

        "notification drain: #{result['sent']} sent, #{result['failed']} failed (retried later), " \
          "#{result['refused']} refused (no longer allowlisted), #{result['queued']} still queued" \
          "#{result['error'] ? " — last error: #{result['error']}" : ''}\n"
      end

      # ---- candidates: what a log line means --------------------------------

      def candidate(entry)
        case entry["kind"]
        when "approval.requested"      then approval_candidate(entry)
        when "task.state"              then state_candidate(entry)
        when "task.retries_exhausted"  then exhausted_candidate(entry)
        when "job.held"                then held_candidate(entry)
        end
      end

      def approval_candidate(entry)
        id = entry["approval_id"].to_s
        return nil if id.empty?

        task = Work.find_task(entry["task_id"])
        { "condition" => "approval", "key" => "approval:#{id}", "approval_id" => id,
          "responsibility_id" => task && task["responsibility_id"],
          "text" => approval_text(id, entry, task) }
      end

      # A move to NEEDS_APPROVAL is deliberately not a candidate of its own: every
      # approval already writes approval.requested, and a person cannot act on a state
      # with no approval behind it.
      def state_candidate(entry)
        to = entry["to"].to_s.upcase
        return nil unless %w[DONE FAILED BLOCKED].include?(to)

        id = entry["task_id"].to_s
        task = Work.find_task(id)
        { "condition" => to.downcase, "key" => "task:#{id}:#{to}",
          "responsibility_id" => task && task["responsibility_id"],
          "text" => state_text(to, id, task, entry["note"]) }
      end

      # record_retry emits task.state FAILED and then retries_exhausted. Both carry the
      # same condition and key, so the pair collapses to the one message.
      def exhausted_candidate(entry)
        id = entry["task_id"].to_s
        { "condition" => "failed", "key" => "task:#{id}:FAILED",
          "responsibility_id" => Work.find_task(id)&.dig("responsibility_id"),
          "text" => state_text("FAILED", id, Work.find_task(id),
                               "gave up after #{entry['attempts']} attempt(s)") }
      end

      # A held job already parked an approval (Policy.check did), and that approval's
      # request is the message; when there is one, keying on it means the hold does not
      # produce a second message. A hold with no approval still notifies.
      def held_candidate(entry)
        approval = entry["approval"].to_s
        key = approval.empty? ? "job:#{entry['name']}:held" : "approval:#{approval}"
        { "condition" => "held", "key" => key, "responsibility_id" => nil,
          "approval_id" => (approval.empty? ? nil : approval),
          "text" => held_text(entry) }
      end

      # ---- the words a person reads -----------------------------------------

      def approval_text(id, entry, task)
        lines = ["🔔 RubyClaw needs a person", "",
                 "held: #{entry['action']}",
                 "task: #{entry['task_id']}#{task && task['title'] ? " — #{task['title']}" : ''}",
                 "approval: #{id}"]
        reason = (task && task["note"]) || entry["note"]
        lines << "reason: #{reason}" if reason.to_s.strip != ""
        lines += ["", "grant:  claw work decide #{id} granted",
                  "deny:   claw work decide #{id} denied"]
        lines.join("\n")
      end

      def state_text(state, id, task, note)
        icon = { "DONE" => "✅", "FAILED" => "❌", "BLOCKED" => "⚠️" }.fetch(state, "•")
        lines = ["#{icon} task #{state.downcase}: #{task ? task['title'] : id}", "task: #{id}"]
        reason = note || (task && task["note"])
        lines << "why: #{reason}" if reason.to_s.strip != ""
        lines << "look: claw work show #{id}" if %w[FAILED BLOCKED].include?(state)
        lines.join("\n")
      end

      def held_text(entry)
        lines = ["⚠️ scheduled job held by policy", "job: #{entry['name']}",
                 "#{entry['action']} = #{entry['policy']} — it did NOT run"]
        lines << "grant: claw work decide #{entry['approval']} granted" if entry["approval"].to_s != ""
        lines.join("\n")
      end

      # ---- small helpers ----------------------------------------------------

      def reporting_for(responsibility_id)
        id = responsibility_id.to_s.strip
        return DEFAULT_REPORTING if id.empty?

        r = Work.find_responsibility(id)
        r ? canonical(r["reporting"]) : DEFAULT_REPORTING
      end

      def queued_item(chat, cand, key, now)
        { "id" => Work.new_id("n"), "chat" => chat.to_i, "text" => cand["text"].to_s[0, MAX_TEXT],
          "key" => key, "condition" => cand["condition"], "approval_id" => cand["approval_id"],
          "attempts" => 0, "queued" => now.utc.iso8601, "last_error" => nil }
      end

      def trim_seen(seen)
        seen.to_a.last(SEEN_MAX).to_h
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
