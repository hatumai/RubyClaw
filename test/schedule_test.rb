# frozen_string_literal: true
require_relative "test_helper"
require "time"
require_relative "../lib/schedule"

# Scheduling, including the part that only shows up after a power cut.
#
# The specs and the date arithmetic are pure functions and are tested directly. Anything
# that writes (the store, job logs, the crontab) runs in a Sandbox, so the machine's own
# data/ and -- more to the point -- its real crontab are never touched.
class ScheduleTest < Minitest::Test
  include ClawTest

  S = RubyClaw::Schedule

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
  end

  # ---- specs ---------------------------------------------------------------------

  def test_specs_are_understood
    assert_equal 900, S.parse_spec("every 15m")["seconds"]
    assert_equal 60, S.parse_spec("every 1 minute")["seconds"]
    assert_equal 7200, S.parse_spec("every 2h")["seconds"]
    assert_equal 3600, S.parse_spec("hourly")["seconds"]
    assert_equal({ "kind" => "daily", "hour" => 7, "minute" => 30 }, S.parse_spec("daily 07:30"))
    assert_equal({ "kind" => "weekly", "wday" => 1, "hour" => 8, "minute" => 0 },
                 S.parse_spec("weekly mon 08:00"))
  end

  def test_a_spec_it_cannot_read_says_what_it_accepts
    err = assert_raises(RubyClaw::Error) { S.parse_spec("whenever you feel like it") }
    assert_match(/every 15m/, err.message)
    assert_raises(RubyClaw::Error) { S.parse_spec("daily 25:00") }
    assert_raises(RubyClaw::Error) { S.parse_spec("weekly someday 08:00") }
  end

  def test_a_spec_reads_back_as_it_was_written
    { "every 15m" => "every 15m", "every 2h" => "every 2h", "hourly" => "hourly",
      "daily 07:30" => "daily 07:30", "weekly mon 08:00" => "weekly mon 08:00" }.each do |spec, want|
      assert_equal want, S.describe(S.parse_spec(spec).merge("name" => "x"))
    end
  end

  # Integer division printed `every 30s` as "every 0m" and `every 90m` as "every 1h" -- the
  # listing said something the schedule does not do.
  def test_odd_intervals_read_back_as_they_were_written
    { "every 30s" => "every 30s", "every 45s" => "every 45s", "every 1m" => "every 1m",
      "every 15m" => "every 15m", "every 90m" => "every 1h30m", "every 3h" => "every 3h" }.each do |spec, want|
      assert_equal want, S.describe(S.parse_spec(spec).merge("name" => "x"))
    end
  end

  # A fixed 86 400 s step looks right until a clock change: measured in America/Denver, a
  # 07:30 job was dated 08:30 the morning after the spring change and 06:30 after the autumn
  # one -- for half the year, every day, silently.
  def test_a_daily_job_does_not_drift_across_a_clock_change
    with_env("TZ" => "America/Denver") do
      spring = S.next_daily(Time.local(2026, 3, 7, 10, 0), 7, 30)
      assert_equal [2026, 3, 8, 7, 30], [spring.year, spring.month, spring.day, spring.hour, spring.min]

      autumn = S.next_daily(Time.local(2026, 10, 31, 10, 0), 7, 30)
      assert_equal [2026, 11, 1, 7, 30], [autumn.year, autumn.month, autumn.day, autumn.hour, autumn.min]

      weekly = S.next_weekly(Time.local(2026, 3, 7, 10, 0), 0, 8, 0)     # the next Sunday
      assert_equal [2026, 3, 8, 8, 0], [weekly.year, weekly.month, weekly.day, weekly.hour, weekly.min]
    end
  end

  # `every 0m` is due forever: it never leaves the due set and holds one of the five slots
  # per tick for the life of the machine.
  def test_an_interval_of_zero_is_refused
    assert_raises(RubyClaw::Error) { S.parse_spec("every 0m") }
    assert_raises(RubyClaw::Error) { S.parse_spec("every 0s") }
  end

  def test_the_next_run_is_strictly_in_the_future
    now = Time.local(2026, 3, 4, 10, 0, 0)
    interval = S.parse_spec("every 15m")
    assert_equal now + 900, S.next_at(interval, from: now)

    daily = S.parse_spec("daily 07:30")
    nxt = S.next_at(daily, from: now)
    assert_equal Time.local(2026, 3, 5, 7, 30), nxt, "07:30 has passed today, so tomorrow"
    assert_equal Time.local(2026, 3, 4, 7, 30), S.next_at(daily, from: Time.local(2026, 3, 4, 6, 0))

    weekly = S.parse_spec("weekly mon 08:00")
    nxt = S.next_at(weekly, from: Time.local(2026, 3, 4, 10, 0))     # a Wednesday
    assert_equal 1, nxt.wday
    assert_operator nxt, :>, now
  end

  # One unparseable timestamp used to rescue around the *whole* collection and then return
  # every enabled job, so a single corrupt entry ran the entire schedule at once, on the
  # spot. The decision is per job now.
  def test_one_corrupt_timestamp_does_not_run_the_whole_schedule
    jobs = [{ "name" => "corrupt", "enabled" => true, "next_run" => "not-a-time" },
            { "name" => "later", "enabled" => true, "next_run" => (Time.now + 3600).utc.iso8601 },
            { "name" => "off", "enabled" => false, "next_run" => nil }]
    assert_equal(["corrupt"], S.due(jobs: jobs).map { |j| j["name"] })
  end

  # ---- running --------------------------------------------------------------------

  def test_jobs_persist_to_disk_and_survive_a_restart
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      RubyClaw::Schedule.add(name: "nightly", spec: "daily 03:00", command: "echo hi")
      puts RubyClaw::Schedule.load.map { |j| "#{j['name']}=#{RubyClaw::Schedule.describe(j)}" }
      # a second process, as after a reboot
      puts RubyClaw::Schedule.load.size
    RB
    assert st.success?, out
    assert_match(/nightly=daily 03:00/, out)
    assert File.exist?(File.join(@sb.dir, "data", "schedule.json")), "the store is on disk"
  end

  def test_a_duplicate_name_is_refused_and_a_removal_is_reported
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.add(name: "a", spec: "hourly", command: "true")
      begin
        S.add(name: "a", spec: "hourly", command: "true")
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
      puts "removed=#{S.remove('a')} then=#{S.remove('a')}"
    RB
    assert st.success?, out
    assert_match(/already exists/, out)
    assert_match(/removed=true then=false/, out)
  end

  # Six writers at once, each in its own process: read-modify-write without the flock
  # loses jobs -- the last writer to save wins and the others vanish silently.
  def test_parallel_writers_do_not_lose_a_job
    threads = 6.times.map do |i|
      Thread.new do
        @sb.ruby(%(require "boot"; require "schedule"; ) +
                 %(RubyClaw::Schedule.add(name: "job#{i}", spec: "hourly", command: "true")))
      end
    end
    threads.each(&:join)

    out, = @sb.ruby('require "boot"; require "schedule"; puts RubyClaw::Schedule.load.map { |j| j["name"] }.sort.join(",")')
    assert_equal "job0,job1,job2,job3,job4,job5", out.strip
  end

  # ---- running -------------------------------------------------------------------

  def test_a_job_that_missed_its_window_runs_once_and_not_a_hundred_times
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"; require "json"
      S = RubyClaw::Schedule
      S.add(name: "missed", spec: "every 1m", command: "echo ran")
      store = S::STORE
      data = JSON.parse(File.read(store))
      data["jobs"][0]["next_run"] = (Time.now.utc - 7200).iso8601     # two hours overdue
      File.write(store, JSON.generate(data))

      results = S.run_due
      puts "runs=#{results.size} ok=#{results.all? { |r| r['ok'] }}"
      job = S.load.first
      puts "runs_recorded=#{job['runs']} next_in_future=#{Time.parse(job['next_run']) > Time.now}"
      puts "status=#{job['last_status']}"
    RB
    assert st.success?, out
    assert_match(/runs=1 ok=true/, out, "an overdue job runs exactly once per tick")
    assert_match(/runs_recorded=1 next_in_future=true/, out)
    assert_match(/status=ok/, out)
  end

  def test_a_failing_job_is_recorded_as_failed_and_its_output_is_kept
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.add(name: "broken", spec: "hourly", command: "echo oops >&2; exit 4")
      r = S.run_job(S.load.first)
      job = S.load.first
      puts "ok=#{r['ok']} status=#{job['last_status']} runs=#{job['runs']}"
      puts File.read(S.log_path("broken"))
    RB
    assert st.success?, out
    assert_match(/ok=false status=failed runs=1/, out)
    assert_match(/oops/, out, "the output that explains the failure must be logged")
  end

  def test_a_timeout_is_recorded_rather_than_left_running
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.add(name: "slow", spec: "hourly", command: "sleep 60", timeout: 2)
      r = S.run_job(S.load.first)
      puts "ok=#{r['ok']} seconds=#{r['seconds']} timed_out=#{r['output'].include?('TIMEOUT')}"
    RB
    assert st.success?, out
    assert_match(/ok=false/, out)
    assert_match(/timed_out=true/, out)
  end

  def test_an_objective_view_of_what_is_due
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.add(name: "due", spec: "hourly", command: "true")
      S.add(name: "paused", spec: "hourly", command: "true")
      S.set_enabled("paused", false)
      puts "due=#{S.due.map { |j| j['name'] }.join(',')}"
    RB
    assert st.success?, out
    assert_match(/due=due/, out)
  end

  # ---- surviving a reboot ---------------------------------------------------------

  # The crontab belongs to the user, not to this program: their lines are never
  # reformatted, reordered or dropped, and installing twice does not stack blocks.
  def test_install_boot_adds_one_block_and_removal_restores_the_crontab_exactly
    state = @sb.path("crontab-state")
    stub = @sb.path("bin", "crontab")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, <<~SH)
      #!/bin/sh
      case "$1" in
        -l) [ -s #{state} ] && cat #{state} || echo "no crontab" ;;
        -)  cat > #{state} ;;
        *)  exit 2 ;;
      esac
    SH
    File.chmod(0o755, stub)
    theirs = "*/15 * * * * /home/user/backup.sh\n0 3 * * 0 /home/user/weekly.sh\n"
    File.write(state, theirs)

    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      puts S.install_boot(interval: 10)
      puts "installed=#{S.boot_installed?}"
      puts "--- after two installs ---"
      S.install_boot(interval: 10)
      puts S.crontab.lines.count { |l| l.include?("rubyclaw:schedule:begin") }
      puts "--- their lines ---"
      puts S.crontab
      S.remove_boot
      puts "--- after removal ---"
      puts S.crontab
    RB
    assert st.success?, out
    assert_match(%r{@reboot .*rubyclaw schedd}, out)
    assert_match(%r{\*/10 \* \* \* \* .*rubyclaw schedd --once}, out)
    assert_match(/installed=true/, out)
    blocks = out.split("--- after two installs ---").last.split("\n").reject(&:empty?).first.to_i
    assert_equal 1, blocks, "installing twice must not stack blocks"

    after = out.split("--- after removal ---").last
    assert_includes after, "/home/user/backup.sh"
    assert_includes after, "/home/user/weekly.sh"
    refute_includes after, "rubyclaw", "removal must leave nothing of ours behind"
    assert_equal theirs, File.read(state)
  end

  # --serve arms the bot at boot as well, in its own block. Before this, a reboot brought the
  # scheduler back and left the bot down: "leave it running" had an expiry date nobody could see.
  def test_install_boot_serve_arms_the_bot_too_and_removes_both_blocks
    state = @sb.path("crontab-state")
    stub = @sb.path("bin", "crontab")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, <<~SH)
      #!/bin/sh
      case "$1" in
        -l) [ -s #{state} ] && cat #{state} || echo "no crontab" ;;
        -)  cat > #{state} ;;
        *)  exit 2 ;;
      esac
    SH
    File.chmod(0o755, stub)
    theirs = "*/15 * * * * /home/user/backup.sh\n"
    File.write(state, theirs)

    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.install_boot(serve: true)
      puts "bot_installed=#{S.serve_installed?}"
      S.install_boot(serve: true)
      puts "serve blocks=#{S.crontab.lines.count { |l| l.include?("rubyclaw:serve:begin") }}"
      puts "schedule blocks=#{S.crontab.lines.count { |l| l.include?("rubyclaw:schedule:begin") }}"
      puts S.crontab
      S.remove_boot(serve: true)
      puts "--- after removal ---"
      puts S.crontab
    RB
    assert st.success?, out
    assert_match(/bot_installed=true/, out)
    assert_match(%r{@reboot .*rubyclaw up --telegram-only --if-not-running}, out)
    # and a keeper, because @reboot alone means a bot that dies at 3am stays dead
    assert_match(%r{\*/5 \* \* \* \* .*rubyclaw up --telegram-only --if-not-running}, out)
    assert_match(/serve blocks=1/, out)
    assert_match(/schedule blocks=1/, out)
    after = out.split("--- after removal ---").last
    assert_includes after, "/home/user/backup.sh"
    refute_includes after, "rubyclaw", "removing both blocks must leave nothing of ours behind"
    assert_equal theirs, File.read(state)
  end

  # A block written by an older version, or typed by hand, says just `# rubyclaw:serve:begin`.
  # It must be replaced rather than left in place beside a new one.
  def test_a_bare_marker_block_is_replaced_rather_than_stacked
    state = @sb.path("crontab-state")
    File.write(state, "# rubyclaw:serve:begin\n@reboot old-command\n# rubyclaw:serve:end\n" \
                      "0 5 * * * /home/user/theirs.sh\n")
    stub = @sb.path("bin", "crontab")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, "#!/bin/sh\ncase \"$1\" in -l) cat #{state} ;; -) cat > #{state} ;; *) exit 2 ;; esac\n")
    File.chmod(0o755, stub)

    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      RubyClaw::Schedule.install_boot(serve: true)
      puts "markers=#{RubyClaw::Schedule.crontab.lines.count { |l| l.include?("rubyclaw:serve:begin") }}"
      puts RubyClaw::Schedule.crontab
    RB
    assert st.success?, out
    assert_match(/markers=1/, out)
    refute_includes out, "old-command", "the stale block should be gone, not duplicated"
    assert_includes out, "/home/user/theirs.sh", "their own line is not ours to drop"
    assert_match(/--if-not-running/, out, "and the new block is the current one")
  end

  # Same protection as the scheduler's block, on the bot's markers: a BEGIN with no END means the
  # lines after it may be the user's, so this refuses to edit rather than guess where they stop.
  def test_a_half_removed_serve_block_is_refused_not_obeyed
    state = @sb.path("crontab-state")
    File.write(state, "# rubyclaw:serve:begin\n@reboot something\n0 4 * * * /home/user/important.sh\n")
    stub = @sb.path("bin", "crontab")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, "#!/bin/sh\ncase \"$1\" in -l) cat #{state} ;; -) cat > #{state} ;; *) exit 2 ;; esac\n")
    File.chmod(0o755, stub)

    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      begin
        RubyClaw::Schedule.install_boot(serve: true)
        puts "NO ERROR (bad)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/refused: .*without/, out)
    assert_includes File.read(state), "/home/user/important.sh", "their line must survive untouched"
  end

  # ---- the tool ------------------------------------------------------------------

  def test_the_schedule_tool_can_add_list_and_remove
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "registry"; require "builtins"
      puts RubyClaw.call("schedule", { "action" => "add", "name" => "tool-job",
                                       "spec" => "every 30m", "command" => "date" })
      puts RubyClaw.call("schedule", { "action" => "list" })
      puts RubyClaw.call("schedule", { "action" => "remove", "name" => "tool-job" })
      puts RubyClaw.call("schedule", { "action" => "list" })
    RB
    assert st.success?, out
    assert_match(/scheduled tool-job: every 30m/, out)
    assert_match(/tool-job/, out)
    assert_match(/removed tool-job/, out)
    assert_match(/no schedules yet/, out)
  end

  # The scheduler thread beside the chat surfaces: the first version of this started it
  # *after* the Telegram setup, so a machine with no bot token ran no scheduled work at
  # all -- the whole feature silently absent, with no error to notice.
  # The in-process thread beside `claw up` and the cron tick are both live on purpose, so
  # two schedulers read the store in the same instant. Both saw the job as due and both ran
  # it (measured with two concurrent ticks) -- for a job that sends a message or spends
  # money, the worst kind of wrong. Ownership is taken under the store lock before running.
  def test_two_ticks_at_once_run_a_due_job_once
    out, st = @sb.ruby(<<~RB)
      require "boot"; require "schedule"
      RubyClaw::Schedule.add(name: "race", spec: "every 1h", command: "echo tick >> #{@sb.path('ticks.txt')}")
    RB
    assert st.success?, out

    tick = <<~'RB'
      require "boot"; require "schedule"
      sleep(rand * 0.2)                 # widen the window: both read the store at once
      RubyClaw::Schedule.run_due
    RB
    pids = 2.times.map { Process.spawn(ClawTest::RUBY, "-I", @sb.path("lib"), "-e", tick, chdir: @sb.dir) }
    pids.each { |pid| Process.wait(pid) }
    sleep 1.0
    runs = @sb.exist?("ticks.txt") ? @sb.read("ticks.txt").lines.size : 0
    assert_equal 1, runs, "one due job must run once, not once per tick"
  end

  # A job that takes longer than its interval is not started again while it is still going:
  # ownership is taken before the command runs, so the next tick sees it as not due.
  def test_a_job_that_outlives_its_interval_is_not_started_twice
    out, st = @sb.ruby(<<~RB)
      require "boot"; require "schedule"
      RubyClaw::Schedule.add(name: "slow", spec: "every 1m", command: "echo start >> #{@sb.path('slow.txt')}; sleep 2")
      t = Thread.new { RubyClaw::Schedule.run_due }
      sleep 0.8
      RubyClaw::Schedule.run_due          # a second tick arrives mid-run
      t.join
    RB
    assert st.success?, out
    assert_equal 1, @sb.read("slow.txt").lines.size
  end

  # Valid JSON of the wrong shape used to raise a bare TypeError from inside the daemon and
  # stop every scheduled job. `[]`, `null` and a bare string all have to say what is wrong.
  def test_a_schedule_file_of_the_wrong_shape_says_so
    ["[]", "null", "\"jobs\"", "{\"jobs\": null}", "{\"jobs\": {\"a\": 1}}"].each do |bad|
      @sb.write("data/schedule.json", bad)
      out, st = @sb.ruby('require "boot"; require "schedule"; puts RubyClaw::Schedule.load.inspect')
      refute st.success?, "loading #{bad.inspect} must fail loudly"
      assert_match(/not a job list|not valid JSON/, out, "#{bad.inspect} must be explained")
      refute_match(/TypeError|NoMethodError/, out, "#{bad.inspect} must not surface a bare Ruby error")
    end
  end

  # A job that outlives its own interval got a next_run in the past -- computed from the tick
  # that started it -- so it was due again immediately, every tick, forever.
  def test_a_slow_job_is_not_due_again_the_moment_it_finishes
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      S.add(name: "slow", spec: "every 1s", command: "sleep 2")
      S.run_due
      finished = Time.now
      job = S.load.find { |j| j["name"] == "slow" }
      nxt = job["next_run"] && Time.parse(job["next_run"])
      # Compare against the moment the job finished, not against the clock at the instant this
      # line happens to run. Under a loaded suite that gap passed a second, and the slot is only
      # one second out -- so the test was measuring its own latency, one run in fifty.
      puts(nxt && nxt > finished ? "next slot is in the future" : "STILL DUE")
      # What the bound is worth: the bug this guards against put the slot a second *before* the
      # finish. Print it, so a future reader can see the assertion still discriminates.
      puts("next=\#{nxt} finished=\#{finished} last_run=\#{job['last_run']} bug_would_be=\#{Time.parse(job['last_run']) + 1}")
    RB
    assert st.success?, out
    assert_includes out, "next slot is in the future"
  end

  # ---- the crontab ----------------------------------------------------------------

  def test_install_boot_refuses_a_step_cron_cannot_use
    [0, 90, 61, -5].each do |bad|
      err = assert_raises(RubyClaw::Error) { S.install_boot(interval: bad) }
      assert_match(/1\.\.59/, err.message)
    end
  end

  # A path with a space in it splits into two words in a crontab and cron runs something
  # else entirely. Asserted on the text, not by installing: the first version of this test
  # called install_boot in-process and wrote its fake paths into this machine's real crontab.
  def test_a_cron_line_quotes_a_path_with_a_space_in_it
    block = S.cron_block(claw: "/home/a b/rubyclaw", log: "/var/log/my dir/cron.log").join("\n")
    assert_includes block, "'/home/a b/rubyclaw' schedd"
    assert_includes block, ">> '/var/log/my dir/cron.log'"
    refute_match(/(?<!')\/home\/a b/, block, "an unquoted path is two words to cron")

    plain = S.cron_block(claw: "/usr/local/bin/rubyclaw", log: "/tmp/cron.log").join("\n")
    refute_includes plain, "'", "a path that needs no quoting must not get any"
  end

  # ...and the write path, where it belongs: a Sandbox with a stub crontab on PATH.
  def test_install_boot_writes_the_block_through_the_crontab_command
    stub = @sb.path("bin", "crontab")
    @sb.write("bin/crontab", "#!/bin/sh\nif [ \"$1\" = \"-l\" ]; then cat #{@sb.path('state')} 2>/dev/null; exit 0; fi\ncat > #{@sb.path('state')}\n")
    File.chmod(0o755, stub)
    @sb.write("state", "0 3 * * * /home/me/backup.sh\n")

    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      RubyClaw::Schedule.install_boot(claw: "/home/a b/rubyclaw", log: "/tmp/cron.log")
      puts RubyClaw::Schedule.crontab
    RB
    assert st.success?, out
    assert_includes out, "'/home/a b/rubyclaw' schedd"
    assert_includes out, "*/5 * * * *"
    assert_includes out, "0 3 * * * /home/me/backup.sh", "the user's own job stays"
  end

  # The guard that makes the leak above impossible rather than merely absent: an in-process
  # run refuses to write the machine's crontab at all.
  def test_an_in_process_write_to_the_crontab_is_refused
    err = assert_raises(RubyClaw::Error) { S.write_crontab("* * * * * echo nope\n") }
    assert_match(/CLAW_NO_CRONTAB/, err.message)
  end

  # `crontab -l` prints "no crontab for <user>" on some systems and exits 0. Written back as
  # a line, it becomes a job that mails an error every five minutes.
  def test_a_no_crontab_notice_is_not_written_back_as_a_job
    stub = @sb.path("bin", "crontab")
    @sb.write("bin/crontab", "#!/bin/sh\nif [ \"$1\" = \"-l\" ]; then echo 'no crontab for hermanohost'; exit 0; fi\ncat >> #{@sb.path('written')}\n")
    File.chmod(0o755, stub)
    out, st = @sb.ruby(<<~'RB', env: { "PATH" => "#{@sb.path('bin')}:#{ENV['PATH']}" })
      require "boot"; require "schedule"
      puts RubyClaw::Schedule.crontab.inspect
    RB
    assert st.success?, out
    assert_equal '""', out.strip, "a notice is not a crontab line"
  end

  # The README promises the user's own lines are untouched. Blank lines between them are
  # part of that: an earlier version dropped them on install and never put them back.
  def test_a_users_own_crontab_lines_survive_install_and_remove
    mine = "PATH=/usr/bin:/bin\n\n0 3 * * * /home/me/backup.sh\n# a comment of mine\n"
    @sb.write("data/crontab.in", mine)
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      S = RubyClaw::Schedule
      before = File.read(File.expand_path("data/crontab.in"))
      stripped = S.without_block(before + "#{S::CRON_BEGIN}\n@reboot thing\n#{S::CRON_END}\n")
      puts(stripped == before ? "round trip byte for byte" : "CHANGED: #{stripped.inspect}")
      puts(stripped.include?("0 3 * * *") && stripped.include?("# a comment of mine") ? "my lines kept" : "LOST LINES")
    RB
    assert st.success?, out
    assert_includes out, "round trip byte for byte"
    assert_includes out, "my lines kept"
  end

  # A bad timestamp in one entry crashed `claw schedule list` with a raw ArgumentError after
  # it had already printed the earlier jobs.
  def test_a_listing_survives_an_unreadable_timestamp
    assert_equal "—", S.next_run_display("next_run" => nil)
    assert_match(/unreadable/, S.next_run_display("next_run" => "not-a-timestamp"))
    assert_match(/\d{4}-\d{2}-\d{2}/, S.next_run_display("next_run" => Time.now.utc.iso8601))
  end

  # deliver: telegram asked for a method that did not exist, and deliver's own rescue wrote
  # the failure into the job log -- where a working job and a broken one look the same. This
  # drives a real POST at a socket.
  # This used a hand-rolled one-shot socket server until it stalled on a Pi Zero: the stub
  # received the whole request (headers and body) and wrote its reply, and Net::HTTP still sat
  # there until its read timeout, thirty seconds later. The product was fine -- a real job
  # delivered to a real chat from that board, and the same POST completed in a standalone probe --
  # so the bespoke stub was replaced by the one the Telegram tests already use, which models the
  # API properly (including Connection: close) and passes on that board.
  #
  # The destination comes from the test's own config.yml, not the machine's. target_chats unions
  # config.yml's telegram_allowed_chat_ids with CLAW_TELEGRAM_ALLOWED, so an in-process run read
  # the operator's real allowlist on the board in addition to the fixture and the result was
  # "telegram: 999999999, 42" where the test asserted "telegram: 42". The sandbox is handed the
  # fixture below, so the test now depends on nothing but its own tree.
  def test_a_telegram_delivery_really_posts_to_the_bot_api
    tg = ClawTest::FakeTG.new
    @sb.write("config.yml", "telegram_allowed_chat_ids: [42]\n")
    env = { "CLAW_TELEGRAM_TOKEN" => "123:abc", "CLAW_TELEGRAM_API_BASE" => tg.base }
    out, st = @sb.ruby(<<~RB, env: env)
      require "boot"; require "schedule"
      puts RubyClaw::Schedule.notify("hello from a job")
    RB
    assert st.success?, out
    assert_match(/telegram: 42/, out)
    assert_includes tg.calls, "sendMessage"
    assert_equal 42, tg.sent.first[:chat_id].to_i
    assert_equal "hello from a job", tg.sent.first[:text]
  ensure
    tg&.stop
  end

  # A BEGIN with no END used to swallow everything after it, and the user's own jobs live
  # down there: losing them to a half-removed block is worse than refusing to touch the file.
  def test_a_crontab_block_without_its_end_marker_is_refused
    err = assert_raises(RubyClaw::Error) do
      S.without_block("0 3 * * * /home/me/backup.sh\n#{S::CRON_BEGIN}\n*/5 * * * * thing\n")
    end
    assert_match(/without/, err.message)
  end

  def test_the_scheduler_thread_runs_a_job_while_the_harness_is_up
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "chat"; require "schedule"
      chat = RubyClaw::Chat.new(model: "m", base_url: "http://127.0.0.1:9/v1", api_key: "k")
      chat.start_scheduler                       # no jobs yet: must be quiet
      RubyClaw::Schedule.add(name: "prompt", spec: "every 1h", command: "echo ran-from-the-thread")
      chat.start_scheduler
      sleep 2
      path = RubyClaw::Schedule.log_path("prompt")
      puts File.exist?(path) ? File.read(path) : "NOTHING RAN"
    RB
    assert st.success?, out
    refute_match(/NOTHING RAN/, out, "the scheduler thread must pick up a due job")
    assert_match(/ran-from-the-thread/, out)
  end

  def test_the_term_and_browser_tools_are_on_the_surface
    names = RubyClaw.schemas.map { |s| s[:function][:name] }
    %w[term browser schedule].each { |n| assert_includes names, n }
    schema = RubyClaw.schemas.find { |s| s[:function][:name] == "browser" }[:function]
    assert_equal %w[action], schema[:parameters][:required]
  end

  # ---- the policy gate at the scheduler -----------------------------------------
  #
  # The policy gate governs *tool calls* in the dispatch path, but the scheduler runs a
  # shell job's command itself, so an unattended `sh` job never passed the policy at all.
  # That is closed here: the daemon's tick is gated, and a shell job under `shell.run: ask`
  # holds instead of running.

  # A task job is a prompt for the harness's own model, and each tool call that model makes
  # is gated in the dispatch path already -- gating the prompt too would ask twice. Only a
  # shell job is held at the scheduler. (The task path returns before the policy is read, so
  # this is safe to exercise in-process.)
  def test_only_a_shell_job_is_gated_at_the_scheduler
    assert_nil S.unattended_hold("mode" => "task", "command" => "summarise the notes")
  end

  # With the shipped policy (shell.run: ask) an unattended shell job holds: it does not run,
  # it is recorded as held, and the policy parks a real approval (stage B's mechanism, not a
  # second one). This is the hole closed; the consequence is documented in README/REVIEW.
  def test_an_unattended_shell_job_is_held_by_policy_instead_of_running
    out, st = @sb.ruby(<<~'RB', env: { "CLAW_POLICY" => nil })
      require "boot"; require "schedule"; require "work"
      S = RubyClaw::Schedule
      S.add(name: "shelljob", spec: "hourly", command: "echo RAN > ran.txt")
      r = S.run_due.first
      puts "held=#{r['held']} ok=#{r['ok']}"
      puts "ran=#{File.exist?('ran.txt')}"
      job = S.load.first
      puts "status=#{job['last_status']} runs=#{job['runs']}"
      puts "approval=#{RubyClaw::Work.pending_approvals.map { |a| a['action'] }.inspect}"
      puts "logged=#{RubyClaw::Work.events.any? { |e| e['kind'] == 'job.held' }}"
    RB
    assert st.success?, out
    assert_match(/held=true ok=false/, out)
    assert_match(/ran=false/, out, "a held job must not run its command")
    assert_match(/status=held runs=0/, out, "it did not run, so it did not count as a run")
    assert_match(/approval=\["shell\.run"\]/, out, "the policy parks a real approval")
    assert_match(/logged=true/, out, "the hold is in the work event log")
    refute @sb.exist?("ran.txt")
  end

  # ...and when the policy allows it, the same shell job runs. The gate is not a blanket block.
  def test_a_shell_job_runs_when_the_policy_allows_it
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "schedule"
      RubyClaw::Schedule.add(name: "ok", spec: "hourly", command: "echo RAN > ran.txt")
      r = RubyClaw::Schedule.run_due.first
      puts "held=#{r['held'].inspect} ok=#{r['ok']} ran=#{File.exist?('ran.txt')}"
    RB
    assert st.success?, out
    assert_match(/held=nil ok=true ran=true/, out)
  end

  # A person's own `claw schedule run` is not gated: a person is present, and if the model
  # reached it, `schedule.manage` already held the call. run_job defaults to ungated.
  def test_a_persons_schedule_run_is_not_gated
    out, st = @sb.ruby(<<~'RB', env: { "CLAW_POLICY" => nil })
      require "boot"; require "schedule"
      RubyClaw::Schedule.add(name: "manual", spec: "hourly", command: "echo RAN > ran.txt")
      r = RubyClaw::Schedule.run_job(RubyClaw::Schedule.load.first)
      puts "held=#{r['held'].inspect} ran=#{File.exist?('ran.txt')}"
    RB
    assert st.success?, out
    assert_match(/held=nil ran=true/, out)
  end
end
