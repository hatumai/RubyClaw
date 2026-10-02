# frozen_string_literal: true
# The operator view: what is waiting on a person, and how the harness itself is doing.
#
# A dashboard is explicitly out of scope for this project (gap analysis, out-of-scope 14/15),
# so this is the honest substitute: plain text a person reads in a terminal, in the order
# that helps -- what needs you first, then what is running, then what broke, then what has
# gone stale, then the harness's own vitals. It is a view: it reads stores and the machine,
# it writes nothing, and it never calls a model.
#
# `claw work` remains the full work-store view; `claw status` is the forty-line version a
# person can look at when they come back to a machine that has been running without them.
require "open3"
require "socket"
require "time"
require_relative "work"
require_relative "schedule"
require_relative "heartbeat"
require_relative "notify"
require_relative "telegram"

module RubyClaw
  module Status
    ROWS = 5                # per section: enough to act on, not a dump
    STALE_SECONDS = 86_400  # a day without movement is worth a look

    class << self
      def render(now: Time.now)
        tasks = Work.tasks
        out = +"RubyClaw status — #{now.strftime('%Y-%m-%d %H:%M')}  #{host}\n"
        out << waiting_block(Work.pending_approvals, now)
        out << running_block(tasks, now)
        out << failed_block(tasks, now)
        out << stale_block(tasks, now)
        out << harness_block(now)
        out << "\nfull view: claw work   ·   decide: claw work decide <approval> granted|denied\n"
        out
      end

      # ---- what is waiting on a person --------------------------------------

      # The exact command, not just the fact that something is pending. This is the one
      # block a person acts on, so it carries the whole action, not a pointer to it.
      def waiting_block(approvals, now)
        return "" if approvals.empty?

        out = +"\nWAITING ON YOU (#{approvals.size})\n"
        approvals.sort_by { |a| age_seconds(a["requested"], now) }.first(ROWS).each do |a|
          task = Work.find_task(a["task_id"])
          out << format("  %-12s %-16s %s\n", a["id"], a["action"].to_s[0, 16],
                        "#{task ? task['title'] : a['task_id']}  (waiting #{age(a['requested'], now)})")
          out << "      grant: claw work decide #{a['id']} granted   deny: claw work decide #{a['id']} denied\n"
        end
        out << "  …and #{approvals.size - ROWS} more — `claw work`\n" if approvals.size > ROWS
        out
      end

      # ---- what is running --------------------------------------------------

      def running_block(tasks, now)
        rows = tasks.select { |t| Work::OPEN_STATES.include?(t["state"]) }
        rows.reject! { |t| Work::ATTENTION.include?(t["state"]) }
        return "\nRUNNING / OPEN (0)\n" if rows.empty?

        out = +"\nRUNNING / OPEN (#{rows.size})\n"
        rows.sort_by { |t| -age_seconds(t, now) }.first(ROWS).each do |t|
          out << format("  %-15s %-14s %-6s %s%s\n", t["state"], t["id"], age(t, now), t["title"],
                        due_note(t, now))
        end
        out << "  …and #{rows.size - ROWS} more\n" if rows.size > ROWS
        out
      end

      # ---- what failed, and why ---------------------------------------------

      def failed_block(tasks, now)
        rows = tasks.select { |t| t["state"] == "FAILED" }
        return "" if rows.empty?

        out = +"\nFAILED (#{rows.size})\n"
        rows.sort_by { |t| -age_seconds(t, now) }.first(ROWS).each do |t|
          out << format("  %-14s %-6s %s\n", t["id"], age(t, now), t["title"])
          out << "      #{why(t) || 'no reason recorded'}   (`claw work show #{t['id']}`)\n"
        end
        out << "  …and #{rows.size - ROWS} more\n" if rows.size > ROWS
        out
      end

      # ---- what is stale or past its deadline --------------------------------

      def stale_block(tasks, now)
        rows = tasks.select { |t| Work::OPEN_STATES.include?(t["state"]) }
        rows = rows.select { |t| past_deadline?(t, now) || age_seconds(t, now) > STALE_SECONDS }
        return "" if rows.empty?

        out = +"\nSTALE / PAST DEADLINE (#{rows.size})\n"
        rows.sort_by { |t| -age_seconds(t, now) }.first(ROWS).each do |t|
          out << format("  %-14s %-6s %s\n", t["id"], age(t, now), t["title"])
          out << "      #{past_deadline?(t, now) ? "deadline passed: #{t['deadline']}" : 'no move in over a day'}" \
                 "  — state #{t['state']}\n"
        end
        out << "  …and #{rows.size - ROWS} more\n" if rows.size > ROWS
        out
      end

      # ---- the harness itself -----------------------------------------------

      def harness_block(now)
        out = +"\nHARNESS\n"
        out << "  bot           #{bot_line}\n"
        out << "  scheduler     #{scheduler_line}\n"
        out << "  heartbeat     #{heartbeat_line(now)}\n"
        out << "  notifications #{notify_line}\n"
        out << "  disk          #{disk_line}\n"
        out
      end

      # What is knowable without opening a poll: a token, and who may talk to it. Saying
      # "connected" here would be a claim this process cannot make.
      def bot_line
        token = begin
          Telegram.token
          true
        rescue RubyClaw::Error
          false
        end
        chats = Notify.allowed_chats
        who = chats.empty? ? "no allowlist (every chat is refused)" : "allowlist #{chats.join(', ')}"
        if token
          "token set · #{who}"
        else
          "NO TOKEN · #{who} · notifications queue until one is set"
        end
      end

      def scheduler_line
        jobs = Schedule.load
        active = jobs.count { |j| j["enabled"] != false }
        nxt = jobs.reject { |j| j["enabled"] == false }.filter_map { |j| Schedule.next_run_display(j) }
                  .reject { |s| s.start_with?("—") }.min
        armed = begin
          Schedule.boot_installed? ? "cron installed" : "cron NOT installed"
        rescue StandardError
          "cron unknown"
        end
        "#{jobs.size} job(s), #{active} active · #{armed}#{nxt ? " · next #{nxt}" : ''}"
      end

      def heartbeat_line(now)
        last = Heartbeat.last_pass
        return "no pass recorded yet — `claw heartbeat` runs one" if last.empty?

        bits = ["last pass #{age(last['at'], now)} ago",
                "#{last['created'].to_i} created, #{last['resumed'].to_i} resumed, " \
                "#{last['approvals'].to_i} parked"]
        bits << "notify FAILED: #{last['notify_error']}" if last["notify_error"].to_s != ""
        bits.join(" · ")
      end

      def notify_line
        bits = ["queue #{Notify.queue_depth}"]
        bits << "last sent #{Heartbeat.last_pass['sent'].to_i}" unless Heartbeat.last_pass.empty?
        bits << "#{Notify.digest_count} held for digest" if Notify.digest_count.positive?
        bits << "#{Notify.undeliverable_count} recorded with NO destination" if Notify.undeliverable_count.positive?
        bits.join(" · ")
      end

      # df is the honest, dependency-free way to ask: no gem, no syscall shim. If it is
      # not there, say unknown rather than guess.
      def disk_line
        out, st = Open3.capture2("df", "-Pk", ROOT)
        return "unknown (df unavailable)" unless st.success?

        row = out.lines[1].to_s.split
        return "unknown" if row.size < 6

        total = row[1].to_i
        pct = total.positive? ? (row[2].to_i * 100 / total) : 0
        "#{row[5]} #{pct}% used, #{human_size(row[3])} free"
      rescue StandardError
        "unknown"
      end

      # ---- small helpers ----------------------------------------------------

      def host
        Socket.gethostname
      rescue StandardError
        "?"
      end

      def why(task)
        note = task["note"].to_s.strip
        note.empty? ? nil : note[0, 80]
      end

      def past_deadline?(task, now)
        stamp = task["deadline"].to_s
        return false if stamp.strip.empty?

        Time.parse(stamp) <= now
      rescue StandardError
        false
      end

      def due_note(task, now)
        return "" unless past_deadline?(task, now)

        "  [PAST DEADLINE #{task['deadline'].to_s[0, 16].tr('T', ' ')}]"
      end

      def age(stamp, now)
        Work.human_seconds(age_seconds(stamp, now))
      end

      def age_seconds(stamp, now)
        [now - Time.parse(stamp.to_s), 0].max.round
      rescue StandardError
        0
      end

      def human_size(kb)
        bytes = kb.to_i * 1024
        return format("%.1fG", bytes / 1_073_741_824.0) if bytes >= 1_073_741_824

        format("%.0fM", bytes / 1_048_576.0)
      end
    end
  end
end
