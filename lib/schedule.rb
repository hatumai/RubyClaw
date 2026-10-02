# frozen_string_literal: true
# Recurring work that survives a reboot.
#
# A job is a line of state in data/schedule.json: what to run, when it is next due, when
# it last ran and how it went. The scheduler itself is either `claw up` (a thread beside
# the chat surfaces) or a cron entry that runs `claw schedd --once` every few minutes --
# the second one is what makes a reboot harmless, because it does not depend on anything
# still being in memory. `claw schedule install-boot` writes that cron entry; the
# default is a marked block in your own crontab, which needs no root.
#
# Two decisions worth stating, because they are the difference between a scheduler that
# works after a power cut and one that quietly does nothing:
#
# - **A missed window runs once, late.** If the machine was off at 07:30, the 07:30 job
#   runs when it comes back, and the next run is computed from *then*. The alternative --
#   computing the next run from the missed slot -- makes a job fire repeatedly to "catch
#   up", which for anything that costs money or sends a message is much worse.
# - **A job that has never run is due immediately.** A schedule added five minutes before
#   a reboot must not wait a day to prove it exists.
require "json"
require "time"
require "fileutils"
require "open3"
require_relative "proc"
require_relative "work"
require_relative "policy"

module RubyClaw
  module Schedule
    STORE   = File.join(ROOT, "data", "schedule.json")
    LOCK    = File.join(ROOT, "data", "schedule.lock")
    LOG_DIR = File.join(ROOT, "log", "schedule")
    SERVE_LOG_DIR = File.join(ROOT, "log", "serve")

    # The block `install-boot` owns in the user's crontab. Everything outside these two
    # lines is left exactly as it was found: this edits someone else's crontab.
    CRON_BEGIN = "# rubyclaw:schedule:begin — managed by `claw schedule install-boot`"
    CRON_END   = "# rubyclaw:schedule:end"
    # The bot gets its own block, so a machine can arm one without the other and removal is
    # never ambiguous. Without this, "leave it running" means "until the next reboot": the
    # scheduler came back by itself and the bot did not.
    SERVE_BEGIN = "# rubyclaw:serve:begin — managed by `claw schedule install-boot --serve`"
    SERVE_END   = "# rubyclaw:serve:end"
    WEEKDAYS   = %w[sun mon tue wed thu fri sat].freeze
    MAX_LOG    = 512 * 1024

    class << self
      # ---- specs ------------------------------------------------------------

      # "every 15m" | "every 2h" | "hourly" | "daily 07:30" | "weekly mon 08:00"
      def parse_spec(spec)
        s = spec.to_s.strip.downcase
        case s
        when /\Aevery\s+(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\z/
          secs = Regexp.last_match(1).to_i * unit_seconds(Regexp.last_match(2))
          # `every 0m` is due forever: it never leaves the due set and holds one of the
          # five per-tick slots for the rest of the machine's life.
          raise Error, "an interval has to be at least a second (got #{spec.inspect})" if secs < 1

          { "kind" => "interval", "seconds" => secs }
        when "hourly", "every hour"
          { "kind" => "interval", "seconds" => 3600 }
        when /\A(?:daily|every day|at)\s+(\d{1,2}):(\d{2})\z/
          h, m = Regexp.last_match(1).to_i, Regexp.last_match(2).to_i
          raise Error, "that is not a time of day: #{spec.inspect}" if h > 23 || m > 59

          { "kind" => "daily", "hour" => h, "minute" => m }
        when /\Aweekly\s+([a-z]{3,9})\s+(\d{1,2}):(\d{2})\z/
          day = Regexp.last_match(1)[0, 3]
          raise Error, "unknown weekday #{Regexp.last_match(1).inspect}" unless WEEKDAYS.include?(day)

          h, m = Regexp.last_match(2).to_i, Regexp.last_match(3).to_i
          raise Error, "that is not a time of day: #{spec.inspect}" if h > 23 || m > 59

          { "kind" => "weekly", "wday" => WEEKDAYS.index(day), "hour" => h, "minute" => m }
        else
          raise Error, "cannot read schedule #{spec.inspect}. Try \"every 15m\", \"hourly\", " \
                       "\"daily 07:30\" or \"weekly mon 08:00\"."
        end
      end

      def unit_seconds(unit) = unit.start_with?("s") ? 1 : (unit.start_with?("m") ? 60 : 3600)

      # Seconds rendered the way a person would say them. Integer division was wrong twice:
      # `every 30s` printed as "every 0m", and `every 90m` as "every 1h".
      def human_seconds(secs)
        return "#{secs}s" if secs < 60
        return "#{secs / 60}m" if secs < 3600
        return "#{secs / 3600}h" if (secs % 3600).zero?

        "#{secs / 3600}h#{(secs % 3600) / 60}m"
      end

      def describe(job)
        case job["kind"]
        when "interval"
          secs = job["seconds"].to_i
          return "hourly" if secs == 3600

          "every #{human_seconds(secs)}"
        when "daily"  then format("daily %02d:%02d", job["hour"], job["minute"])
        when "weekly" then format("weekly %s %02d:%02d", WEEKDAYS[job["wday"].to_i], job["hour"], job["minute"])
        else "unknown"
        end
      end

      # The next time this job should run, strictly after `from`.
      def next_at(job, from: Time.now)
        case job["kind"]
        # Ceiling, not the bare sum: the slot is stored as whole seconds (iso8601), so a value with
        # sub-second precision is *truncated* on the way in and can land up to a second in the past
        # -- which makes `due?` fire the job again at once, the very bug this is here to prevent.
        # It also made a test flake: "next slot is in the future" failed about one run in fifty,
        # depending only on the phase of the sub-second clock. Caught in a fresh extraction of the
        # 0.09 archive after the same code had passed locally minutes earlier.
        when "interval" then (from + job["seconds"].to_i).ceil
        when "daily"    then next_daily(from, job["hour"].to_i, job["minute"].to_i)
        when "weekly"   then next_weekly(from, job["wday"].to_i, job["hour"].to_i, job["minute"].to_i)
        end
      end

      # A local wall-clock time. Advance by *calendar days*, re-reading the clock each
      # step: adding 86_400 s instead looks right until a daylight-saving change, at which
      # point a 07:30 job runs at 08:30 for half the year (measured, America/Denver, both
      # directions). An hour that does not exist on the clock (the spring forward) has no
      # 07:30 to run at, so Time.local normalises it forward and the job runs on the shifted
      # clock rather than not at all.
      def next_daily(from, hour, minute)
        require "date"
        day = Date.new(from.year, from.month, from.day)
        loop do
          at = Time.local(day.year, day.month, day.day, hour, minute)
          return at if at > from

          day += 1
        end
      end

      def next_weekly(from, wday, hour, minute)
        require "date"
        day = Date.new(from.year, from.month, from.day)
        loop do
          at = Time.local(day.year, day.month, day.day, hour, minute)
          return at if at > from && at.wday == wday

          day += 1
        end
      end

      # ---- the store --------------------------------------------------------

      def load
        return [] unless File.exist?(STORE)

        data = begin
          JSON.parse(File.read(STORE))
        rescue JSON::ParserError => e
          raise Error, "schedule file is not valid JSON (#{e.message}); fix or delete #{STORE}"
        end
        # Valid JSON of the wrong shape used to raise a bare TypeError from deep inside the
        # daemon ("no implicit conversion of String into Integer"), which reads like a bug in
        # the harness and stops every scheduled job. Say what is wrong and what to do.
        unless data.is_a?(Hash) && data["jobs"].is_a?(Array)
          raise Error, "schedule file is not a job list (expected {\"jobs\": [...]}); " \
                       "fix or delete #{STORE}"
        end

        data["jobs"]
      end

      def save(jobs)
        FileUtils.mkdir_p(File.dirname(STORE))
        tmp = "#{STORE}.#{Process.pid}.tmp"
        File.open(tmp, "w") do |f|
          f.write(JSON.pretty_generate("jobs" => jobs, "updated" => Time.now.utc.iso8601) + "\n")
          # Without this the rename can land while the contents are still in the page cache,
          # so a power cut -- the exact event this module exists to survive -- could leave an
          # empty or half-written store where a valid one used to be.
          f.fsync
        end
        File.rename(tmp, STORE)      # a reader sees the old file or the new one, never half
      end

      # A crash between writing the temp file and renaming it leaves the temp file behind,
      # and nothing else will ever touch it. Called when the store is opened -- but only
      # sweeps files that have been sitting there a while: another writer's temp file is
      # live, and deleting it between its write and its rename loses that writer's job
      # (measured: 3 of 6 concurrent writers vanished). Five minutes is far longer than a
      # rename takes and far shorter than a forgotten file lives.
      STALE_TMP = 300

      def sweep_temp!
        Dir["#{STORE}.*.tmp"].each do |f|
          next unless (Time.now - File.mtime(f)) > STALE_TMP

          File.unlink(f) rescue nil
        end
      rescue StandardError
        nil
      end

      # Read-modify-write under an exclusive lock: the daemon, `claw schedule add` and a
      # cron `--once` run can all be live at the same moment.
      def with_store
        sweep_temp!
        FileUtils.mkdir_p(File.dirname(STORE))
        File.open(LOCK, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          jobs = load
          result = yield jobs
          save(jobs)
          result
        end
      end

      def find(jobs, name) = jobs.find { |j| j["name"] == name.to_s }

      # ---- editing ----------------------------------------------------------

      def add(name:, spec:, command:, mode: "shell", deliver: "log", timeout: nil, enabled: true)
        raise Error, "a schedule needs a name" if name.to_s.strip.empty?
        raise Error, "a schedule needs a command to run" if command.to_s.strip.empty?

        mode = mode.to_s
        raise Error, "mode must be shell or task (got #{mode.inspect})" unless %w[shell task].include?(mode)

        job = { "name" => name.to_s, "command" => command.to_s, "mode" => mode,
                "deliver" => deliver.to_s, "enabled" => enabled, "runs" => 0 }
        job.merge!(parse_spec(spec))
        job["spec"] = spec.to_s
        job["timeout"] = timeout.to_i if timeout
        job["next_run"] = (Time.now.utc + 0.001).iso8601 if enabled   # due now, prove it works
        with_store do |jobs|
          existing = find(jobs, name)
          raise Error, "a schedule called #{name} already exists" if existing

          jobs << job
        end
        job
      end

      def remove(name)
        with_store do |jobs|
          before = jobs.size
          jobs.reject! { |j| j["name"] == name.to_s }
          before != jobs.size
        end
      end

      def set_enabled(name, on, now: Time.now)
        with_store do |jobs|
          job = find(jobs, name) or raise Error, "no schedule called #{name}"
          job["enabled"] = on
          job["next_run"] = on ? (now + 0.001).iso8601 : nil
          job
        end
      end

      # ---- running ----------------------------------------------------------

      # Jobs that are due. A job with no next_run has never run and is due immediately.
      def due(now: Time.now, jobs: nil)
        (jobs || load).select { |j| due?(j, now) }
      end

      # One job's turn. Decided per job: the previous version rescued ArgumentError around
      # the *whole* collection and then returned every enabled job, so a single unparseable
      # timestamp ran the entire schedule at once, immediately.
      def due?(job, now = Time.now)
        return false if job["enabled"] == false
        return true if job["next_run"].nil?

        Time.parse(job["next_run"]) <= now
      rescue ArgumentError
        # A corrupt timestamp is a corrupt entry, not a reason to stop the daemon.
        true
      end

      # Take ownership of due jobs *before* running them.
      #
      # The in-process thread beside `claw up` and the cron tick are both live on purpose,
      # so two schedulers read the store at the same moment and both see the same job as
      # due. Advancing next_run under the lock is what makes the run exclusive; without it
      # the job ran twice (measured with two concurrent ticks), which for a job that sends
      # a message or spends money is the worst kind of wrong.
      def claim(names, now: Time.now)
        claimed = []
        return claimed if names.empty?

        with_store do |jobs|
          names.each do |name|
            live = find(jobs, name)
            next unless live && due?(live, now)

            live["next_run"] = live["enabled"] == false ? nil : next_at(live, from: now)&.utc&.iso8601
            live["claimed_at"] = now.utc.iso8601
            claimed << live
          end
        end
        claimed
      end

      # The daemon's tick: run what is due, through the policy gate (gated: true). A
      # person running `claw schedule run` calls run_job directly and is not gated here --
      # a person is present, and a shell job's command reaching the policy a second time
      # after `schedule.manage` already held it would only ask twice. See hold_unattended.
      def run_due(now: Time.now, limit: 5, gated: true)
        names = due(now: now).first(limit).map { |j| j["name"] }
        claim(names, now: now).map { |job| run_job(job, now: now, gated: gated) }
      end

      # A job's next slot is computed from the moment it *finished*, never from the tick that
      # started it. Computed from the start, a job whose work outlasted its own interval
      # (say `every 1m` with a three-second command, or any slow job) got a next_run in the
      # past and was immediately due again -- every tick, forever.
      def slot_from(now)
        [now, Time.now].max
      end

      # Run one job now, record the outcome, and compute its next slot from *now* (see the
      # note at the top: a missed window is not replayed as a burst). The job is re-read
      # under the lock, so a concurrent `claw schedule remove` wins over a stale copy.
      # `force` used to be a parameter nobody read: the caller decides to run an off-schedule
      # job by calling this directly, so the flag was decoration.
      #
      # `gated: true` is the scheduler's own tick: a shell job's command goes through the
      # autonomy policy first. The policy gate governs *tool calls* in the dispatch path,
      # but the scheduler runs a shell command itself, so without this an unattended
      # `sh` job never saw the policy at all -- `shell.run: ask` held the model's calls
      # and not the scheduler's. A held job does not run; it is recorded as held, and the
      # policy parks the approval (see hold_unattended).
      def run_job(job, now: Time.now, gated: false)
        verdict = gated ? unattended_hold(job) : nil
        return hold_unattended(job, verdict, now: now) if verdict

        started = Time.now
        output, ok = execute(job)
        seconds = (Time.now - started).round(2)

        live = with_store do |jobs|
          live = find(jobs, job["name"]) || job
          live["runs"] = live["runs"].to_i + 1
          live["last_run"] = now.utc.iso8601
          live["last_seconds"] = seconds
          live["last_status"] = ok ? "ok" : "failed"
          # From the *end* of the run, not the start: see slot_from.
          live["next_run"] = (live["enabled"] == false ? nil : next_at(live, from: slot_from(now))&.utc&.iso8601)
          live["last_output"] = output.to_s[0, 2000]
          live
        end
        # A finished run is one line in the work event log too, so the heartbeat's scan can
        # turn `job.finished` into a unified event that a responsibility may match.
        Work.record({ "kind" => "job.finished", "name" => job["name"], "ok" => ok,
                      "ts" => now.utc.iso8601, "runs" => live["runs"] })

        entry = <<~LOG
          [#{now.utc.iso8601}] #{job['name']} (#{describe(job)}) #{ok ? 'ok' : 'FAILED'} in #{seconds}s
          $ #{job['command']}
          #{output.to_s.strip}

        LOG
        append_log(job["name"], entry)
        deliver(job, output, ok, seconds)
        { "name" => job["name"], "ok" => ok, "seconds" => seconds, "output" => output.to_s }
      end

      # A shell job's verdict from the policy, or nil when it may run. A task job is a
      # prompt for the harness's own model, and each tool call that model makes is gated
      # already in the dispatch path -- gating the prompt as well would ask a person
      # twice for one thing. The hole was the raw command, so the raw command is what
      # this covers.
      def unattended_hold(job)
        return nil unless job["mode"].to_s == "shell"

        verdict = Policy.check("sh", { "command" => job["command"] })
        verdict["run"] ? nil : verdict
      end

      # A job the gate held: it did not run. The next slot is advanced (so it does not
      # retry every tick), the outcome is recorded as "held" rather than "failed" (the
      # command is fine, a person has not released it), and the hold is a `job.held` line
      # in the work event log so it is visible in `claw work` and in the schedule log.
      # The approval itself is what Policy.check parked against the store; this method
      # never invents a second approval mechanism.
      def hold_unattended(job, verdict, now: Time.now)
        with_store do |jobs|
          live = find(jobs, job["name"]) || job
          live["last_run"] = now.utc.iso8601
          live["last_status"] = "held"
          live["next_run"] = (live["enabled"] == false ? nil : next_at(live, from: slot_from(now))&.utc&.iso8601)
          live["last_output"] = "held by policy (#{verdict['action']} = #{verdict['policy']}); not run"
          live
        end
        Work.record({ "kind" => "job.held", "name" => job["name"], "action" => verdict["action"],
                      "policy" => verdict["policy"], "approval" => verdict["approval"],
                      "ts" => now.utc.iso8601 })
        append_log(job["name"], "[#{now.utc.iso8601}] #{job['name']} HELD by policy " \
                                "(#{verdict['action']} = #{verdict['policy']}); the command did NOT run.\n\n")
        { "name" => job["name"], "ok" => false, "held" => true, "seconds" => 0,
          "policy" => verdict["policy"], "output" => verdict["message"].to_s }
      end

      # shell = a command on this machine; task = a prompt for the harness's own model.
      def execute(job)
        timeout = (job["timeout"] || 600).to_i
        cmd = if job["mode"] == "task"
                [RbConfig.ruby, File.join(ROOT, "bin", "claw"), "run", job["command"]]
              else
                Proc.shell_command(job["command"])
              end
        r = Proc.run(cmd, timeout: timeout, cwd: ROOT)
        body = [r.out, r.err].reject(&:empty?).join("\n")
        return ["TIMEOUT after #{timeout}s (process group killed)\n#{body}".strip, false] if r.timed_out

        [body.strip, r.code.to_i.zero?]
      end

      def deliver(job, output, ok, seconds)
        return if job["deliver"].to_s == "log" || job["deliver"].to_s.empty?

        text = "#{ok ? '✅' : '❌'} #{job['name']} (#{describe(job)}) #{ok ? 'finished' : 'FAILED'} " \
               "in #{seconds}s\n#{output.to_s.strip[0, 3000]}"
        note = notify(text)
        append_log(job["name"], "delivered: #{note}\n\n") if note
      rescue StandardError => e
        # A delivery failure must not lose the run: it is already logged and recorded.
        append_log(job["name"], "delivery failed: #{e.class}: #{e.message}\n\n")
      end

      # Telegram, without pulling the adapter in: one HTTP call to the Bot API, and the
      # same api_base seam the adapter uses so this can be tested against the stub.
      def notify(text)
        token = ENV["CLAW_TELEGRAM_TOKEN"] || RubyClaw.config["telegram_token"]
        chats = target_chats
        return "no telegram chat configured" if token.to_s.empty? || chats.empty?

        require "net/http"
        base = ENV["CLAW_TELEGRAM_API_BASE"] || "https://api.telegram.org"
        uri = URI("#{base}/bot#{token}/sendMessage")
        sent = chats.map do |chat|
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(chat_id: chat, text: text.to_s[0, 4000])
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
          res.code.to_i == 200 ? chat : "#{chat}=HTTP #{res.code}"
        end
        "telegram: #{sent.join(', ')}"
      end

      # `notify` called target_chats while the method was still called encrypted_chats, so
      # every `deliver: telegram` job raised NoMethodError -- and deliver's own rescue wrote
      # it to the job log, where a working job and a broken one look the same.
      def target_chats
        from_env = ENV["CLAW_TELEGRAM_ALLOWED"].to_s.split(",")
        cfg = Array(RubyClaw.config["telegram_allowed_chat_ids"])
        (cfg + from_env).map { |c| c.to_s.strip }.reject(&:empty?).map(&:to_i).uniq
      end

      def append_log(name, text)
        FileUtils.mkdir_p(LOG_DIR)
        path = File.join(LOG_DIR, "#{name.to_s.gsub(/[^A-Za-z0-9._-]/, '_')}.log")
        FileUtils.mv(path, "#{path}.1") if File.exist?(path) && File.size(path) > MAX_LOG
        File.open(path, "a") { |f| f.write(text) }
      end

      def log_path(name) = File.join(LOG_DIR, "#{name.to_s.gsub(/[^A-Za-z0-9._-]/, '_')}.log")

      # A timestamp a person can read, or a dash. `claw schedule list` and the `schedule`
      # tool both parsed it bare, so one corrupt entry crashed the listing with a raw
      # ArgumentError from inside a formatting step.
      def next_run_display(job)
        raw = job["next_run"]
        return "—" if raw.to_s.empty?

        Time.parse(raw.to_s).getlocal.strftime("%Y-%m-%d %H:%M")
      rescue StandardError
        "— (unreadable timestamp)"
      end

      # The daemon. `--once` is the cron entry: run what is due and exit, so a reboot, a
      # crash or a stolen power cable all converge on the same behaviour. `on_pass` is how
      # the heartbeat rides along (bin/claw and lib/chat.rb pass it): it runs after the due
      # jobs, once per tick, so a job that just finished is already in the event log for the
      # heartbeat's scan. Schedule does not require the heartbeat -- the caller supplies it.
      def daemon(poll: 30, once: false, on_tick: nil, on_pass: nil)
        loop do
          run_due.map { |r| on_tick&.call(r) }
          on_pass&.call
          break if once

          sleep poll
        end
      end

      # ---- surviving a reboot ----------------------------------------------

      def crontab
        out, _err, st = Open3.capture3("crontab", "-l")
        # "no crontab for <user>" exits 1 on some systems, 0 with a message on others. It is
        # a notice, not a line: written back it becomes a job that mails an error every time
        # cron runs it.
        return "" unless st.exitstatus.to_i.zero?
        return "" if out.to_s.strip.match?(/\Ano crontab for\b/i)

        out
      rescue Errno::ENOENT
        raise Error, "no crontab command on this machine: install cron, or run `claw schedd` " \
                     "from your own supervisor (systemd, runit)."
      end

      # A path with a space in it splits into two words in the crontab, and cron runs
      # something else entirely -- or mails an error forever.
      def cron_quote(str)
        s = str.to_s
        s.match?(%r{\A[A-Za-z0-9_@%+=:,./-]+\z}) ? s : "'#{s.gsub("'", %q('\\''))}'"
      end

      # The block itself, as text. Pure, so it can be tested -- and so a test has no reason
      # to install anything: a test that did wrote its fake paths into the developer's own
      # crontab, which is exactly the kind of leak the rest of the suite is careful about.
      def cron_block(interval: 5, claw: File.join(ROOT, "rubyclaw"), log: File.join(LOG_DIR, "cron.log"))
        mins = interval.to_i
        # */0 and */90 are not cron: the first is an error, the second never fires. Both were
        # written verbatim, so the block looked installed and did nothing.
        raise Error, "--every takes minutes 1..59 (got #{interval.inspect})" unless (1..59).cover?(mins)

        cmd = "#{cron_quote(claw)} schedd"
        redir = ">> #{cron_quote(log)} 2>&1"
        [CRON_BEGIN,
         "@reboot #{cmd} #{redir}",
         "*/#{mins} * * * * #{cmd} --once #{redir}",
         CRON_END]
      end

      def serve_block(claw: File.join(ROOT, "rubyclaw"), log: File.join(SERVE_LOG_DIR, "serve.log"))
        # Two lines, mirroring the scheduler's block: one at boot, and one every five minutes as
        # a keeper. @reboot alone means a bot that dies at 3am stays dead until someone reboots
        # -- the promise was "leave it running", not "leave it running until it stops". The
        # keeper cannot start a second poller: --if-not-running checks the pidfile first.
        cmd = "#{cron_quote(claw)} up --telegram-only --if-not-running"
        [SERVE_BEGIN,
         "@reboot #{cmd} >> #{cron_quote(log)} 2>&1",
         "*/5 * * * * #{cmd} >> #{cron_quote(log)} 2>&1",
         SERVE_END]
      end

      def install_boot(interval: 5, claw: File.join(ROOT, "rubyclaw"), log: File.join(LOG_DIR, "cron.log"),
                       serve: false, serve_log: File.join(SERVE_LOG_DIR, "serve.log"))
        FileUtils.mkdir_p(LOG_DIR)
        block = cron_block(interval: interval, claw: claw, log: log)
        text = without_block(crontab) + block.join("\n") + "\n"
        if serve
          FileUtils.mkdir_p(SERVE_LOG_DIR)
          sblock = serve_block(claw: claw, log: serve_log)
          text = without_block(text, SERVE_BEGIN, SERVE_END) + sblock.join("\n") + "\n"
        end
        write_crontab(text)
        block.join("\n")
      end

      def remove_boot(serve: false)
        text = without_block(crontab)
        text = without_block(text, SERVE_BEGIN, SERVE_END) if serve
        write_crontab(text)
        true
      end

      def boot_installed? = crontab.include?(CRON_BEGIN)

      def serve_installed? = crontab.include?(SERVE_BEGIN)

      # Everything the block does not own. Someone else's crontab lines are not this
      # program's to reformat, reorder or drop -- and that includes the blank lines between
      # them, which an earlier version threw away (a blank line is not noise in a file a
      # person maintains by hand).
      #
      # Refuses a BEGIN with no END rather than obeying it: the user's own jobs live after
      # the marker, and losing them to a half-removed block is far worse than refusing.
      def without_block(text, begin_marker = CRON_BEGIN, end_marker = CRON_END)
        raw = text.to_s.split("\n", -1)
        trailing = raw.last == ""
        raw.pop if trailing

        began = raw.index { |l| marker?(l, begin_marker) }
        body = if began.nil?
                 raw
               else
                 ended = raw[(began + 1)..].index { |l| marker?(l, end_marker) }
                 if ended.nil?
                   raise Error, "crontab has #{begin_marker.strip} without #{end_marker.strip}: " \
                                "refusing to edit it, because the lines after it are not ours"
                 end

                 raw[0...began] + raw[(began + ended + 2)..]
               end

        joined = body.join("\n")
        joined.empty? ? "" : (trailing ? "#{joined}\n" : joined)
      end

      # A marker is recognised by its root, not by the exact prose after it. The sentence after
      # the em dash is for the human reading their crontab, and an older block (or one someone
      # typed by hand) that says just `# rubyclaw:serve:begin` must still be removable: matching
      # the full sentence meant a stray marker was neither removed nor refused, and installing
      # again stacked a second block beside it.
      def marker?(line, marker)
        stripped = line.strip
        stripped == marker.strip || stripped.start_with?(marker.split(" — ").first.strip)
      end

      def write_crontab(text)
        # Belt for the suite: an in-process test must never be able to edit the machine's
        # crontab. (It happened -- a test of the quoting wrote its fake paths into the real
        # file -- and a test that wants to exercise the write path does it in a Sandbox with
        # a stub `crontab` on PATH, where this guard is not set.)
        raise Error, "refusing to write the crontab: CLAW_NO_CRONTAB is set" if ENV["CLAW_NO_CRONTAB"]

        _out, err, st = Open3.capture3("crontab", "-", stdin_data: text.to_s)
        raise Error, "crontab refused the change: #{err.to_s.strip[0, 200]}" unless st.exitstatus.to_i.zero?

        true
      end
    end
  end
end
