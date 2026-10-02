# frozen_string_literal: true
require_relative "test_helper"

# The interactive surface: the command set every chat shares, and a full task
# through the local prompt.
class ChatTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("chat")
    @sb.git_init!
  end

  def teardown
    @sb.cleanup
    @llm&.stop
  end

  def chat(env: {})
    with_env(env) { RubyClaw::Chat.new }
  end

  def test_help_lists_the_commands
    out, = capture { chat.dispatch("/help") }
    assert_match(%r{/prefer}, out)
    assert_match(%r{/notes}, out)
    assert_match(%r{/new}, out)
  end

  def test_tools_marks_core_and_self_written
    out, = capture { chat.dispatch("/tools") }
    assert_match(/sh\s+\[core\]/, out)
    assert_match(/sha256\s+\[self\]/, out)
  end

  def test_model_reports_resolution_without_the_key
    out, = capture { chat.dispatch("/model") }
    assert_match(/model\s+\S+/, out)
    assert_match(/key\s+(set|NOT SET)/, out)
  end

  def test_new_resets_the_conversation
    c = chat
    assert_nil c.instance_variable_get(:@session)
    c.session
    refute_nil c.instance_variable_get(:@session)
    assert_equal :handled, c.dispatch("/new")
    assert_nil c.instance_variable_get(:@session)
  end

  def test_quit_and_exit_end_the_loop
    assert_equal :quit, chat.dispatch("/quit")
    assert_equal :quit, chat.dispatch(":exit")
  end

  def test_unknown_command_is_handled_not_sent_to_the_model
    out, = capture { assert_equal :handled, chat.dispatch("/banana") }
    assert_match(/unknown command/, out)
  end

  def test_a_plain_line_is_a_task
    assert_nil chat.dispatch("what is the time")
  end

  # End to end through the real REPL: piped input, a fake model, sandboxed tree.
  def test_a_task_runs_through_the_local_prompt
    @llm = FakeLLM.new(script: [FakeLLM.says("forty-two")])
    out, st = @sb.claw("chat", env: { "CLAW_BASE_URL" => @llm.base_url, "CLAW_MODEL" => "fake",
                                      "CLAW_API_KEY" => "x" },
                       stdin: "what is the answer\n/quit\n")
    assert st.success?, out
    assert_match(/forty-two/, out)
    assert_match(/tokens: /, out)
    assert_equal 1, @llm.call_count
  end

  # /prefer is how the user teaches it, so it must land in preferences.md.
  def test_prefer_in_the_repl_writes_a_preference
    out, st = @sb.claw("chat", stdin: "/prefer always answer in one line\n/prefer\n/quit\n",
                       env: { "CLAW_BASE_URL" => "http://127.0.0.1:1/v1", "CLAW_API_KEY" => "x" })
    assert st.success?, out
    assert_match(/always answer in one line/, @sb.read("preferences.md"))
    assert_match(/usage: \/prefer/, out)
  end

  def test_notes_command_shows_what_it_has_learned
    @sb.write("preferences.md", "# Preferences\n- 2026-01-01 keep it short\n")
    out, = @sb.claw("chat", stdin: "/notes\n/quit\n",
                    env: { "CLAW_BASE_URL" => "http://127.0.0.1:1/v1", "CLAW_API_KEY" => "x" })
    assert_match(/preferences\.md/, out)
    assert_match(/keep it short/, out)
  end

  # A service has no stdin. serve() used to fall through to the prompt after starting Telegram,
  # and the prompt breaks on the first EOF -- so under systemd (stdin /dev/null) the bot came up
  # and then took the whole process down with it, seconds later. This runs the real entry point
  # with a closed stdin, because that is the shape that failed.
  def test_telegram_only_stays_up_with_no_stdin_to_read
    tg = ClawTest::FakeTG.new
    pid = Process.spawn({ "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
                          "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
                          "CLAW_API_KEY" => "x" },
                        ClawTest::RUBY, @sb.path("bin/claw"), "up", "--telegram-only",
                        chdir: @sb.dir, in: File::NULL, out: File::NULL, err: File::NULL)
    # Wait for evidence the bot is actually up, rather than for a fixed three
    # seconds. Boot is slow on a single-core armv6 board, and a SIGTERM that
    # arrives before Ruby has installed its handler kills the process by the
    # default disposition: exitstatus comes back nil and a perfectly clean stop
    # looks unclean. Readiness is the fake server having served a call, which
    # only happens once the bot is running its poll loop.
    connected = false
    exited = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    loop do
      connected = tg.calls.any? { |c| c.to_s.include?("getMe") || c.to_s.include?("getUpdates") }
      break if connected
      if Process.waitpid(pid, Process::WNOHANG)
        exited = true
        break
      end
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end

    refute exited, "the bot process exited as soon as it had no stdin to read"
    assert connected, "the bot never reached the Telegram API within 60s"

    Process.kill("TERM", pid)
    _, status = Process.wait2(pid)
    assert_equal 0, status.exitstatus, "a service stop should be clean"
  ensure
    tg&.stop
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  # Cron does not know another keeper is running, so two can fire in the same instant, and on a
  # slow board the first is still connecting when the second starts. Both used to come up -- two
  # pollers on one token, Telegram terminating one of them, and the user's chat half-working.
  # The claim is created with O_EXCL before the connect for exactly this: whoever creates it wins.
  def test_two_keepers_firing_together_produce_one_bot
    tg = ClawTest::FakeTG.new(delay: 1.5)
    env = { "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
            "CLAW_API_KEY" => "x" }
    spawn_keeper = lambda do
      Process.spawn(env, ClawTest::RUBY, @sb.path("bin/claw"), "up", "--telegram-only",
                    "--if-not-running", chdir: @sb.dir, in: File::NULL,
                    out: File::NULL, err: File::NULL)
    end
    a = spawn_keeper.call
    b = spawn_keeper.call
    sleep 8

    alive = [a, b].reject { |p| Process.waitpid(p, Process::WNOHANG) }
    assert_equal 1, alive.size, "exactly one of two simultaneous keepers should survive"

    survivor = alive.first
    assert_equal survivor, File.read(@sb.path("data", "serve.pid")).to_i,
                 "the pidfile should name the survivor"
    Process.kill("TERM", survivor)
    Process.wait2(survivor)
    refute File.exist?(@sb.path("data", "serve.pid")), "the claim should not outlive the bot"
  ensure
    tg&.stop
    [a, b].compact.each do |p|
      Process.kill("KILL", p) rescue nil
      Process.wait(p) rescue nil
    end
  end

  # A bot that crashed leaves its pid behind. That debris must not block its own replacement until
  # somebody notices, and the replacement must know the file is now its own.
  def test_a_dead_process_claim_does_not_block_a_new_bot
    tg = ClawTest::FakeTG.new
    @sb.write("data/serve.pid", "999999\n")          # a pid nothing owns
    log = @sb.path("log", "deadclaim.log")
    env = { "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
            "CLAW_API_KEY" => "x" }
    pid = Process.spawn(env, ClawTest::RUBY, @sb.path("bin/claw"), "up", "--telegram-only",
                        "--if-not-running", chdir: @sb.dir, in: File::NULL,
                        out: log, err: log)
    # Wait for the bot to say it connected, rather than for a fixed number of seconds: booting
    # this tree is about a second on a Pi 4 and 7-8 s on the armv6 board, so "sleep 6, then read
    # the log" read an empty log there and reported the product broken when it was only slow.
    # The deadline is a hang guard, not an expectation about speed.
    out = File.read(log)
    wait_until = Time.now + 120
    while !out.include?("connected") && Time.now < wait_until
      assert Process.waitpid(pid, Process::WNOHANG).nil?, "the new bot exited before it connected"
      sleep 0.5
      out = File.read(log)
    end
    assert Process.waitpid(pid, Process::WNOHANG).nil?, "a dead claim should not stop a new bot"
    refute_match(/already running/, out)
    assert_match(/connected/, out)
    assert_equal pid, File.read(@sb.path("data", "serve.pid")).to_i, "the new bot owns the claim"
  ensure
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
    tg&.stop
  end

  # Only the process the claim names may remove it. Removing it unconditionally meant a dying old
  # instance deleted the live instance's file, and the next keeper run then started a third poller.
  def test_a_dying_instance_does_not_delete_a_live_claim
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "chat"
      pidfile = File.join(RubyClaw::ROOT, "data", "serve.pid")
      FileUtils.mkdir_p(File.dirname(pidfile))
      File.write(pidfile, "1\n")                      # pid 1: alive, and not us
      RubyClaw::Chat.release_served!
      puts "foreign survives: #{File.exist?(pidfile)}"
      File.write(pidfile, "#{Process.pid}\n")         # ours
      RubyClaw::Chat.release_served!
      puts "ours removed: #{!File.exist?(pidfile)}"
    RB
    assert st.success?, out
    assert_match(/foreign survives: true/, out)
    assert_match(/ours removed: true/, out)
  end

  # Two pollers on one bot token steal each other's messages, so the keeper that cron runs every
  # five minutes must be a no-op when the bot is already up. This runs the real entry point twice
  # against a stub Bot API: the first stays, the second must exit 0 immediately, saying so.
  def test_a_second_keeper_run_refuses_to_start_a_second_poller
    tg = ClawTest::FakeTG.new
    env = { "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
            "CLAW_API_KEY" => "x" }
    pid = Process.spawn(env, ClawTest::RUBY, @sb.path("bin/claw"), "up", "--telegram-only",
                        "--if-not-running", chdir: @sb.dir, in: File::NULL,
                        out: File::NULL, err: File::NULL)
    sleep 3
    refute Process.waitpid(pid, Process::WNOHANG), "the first bot should still be running"
    assert File.exist?(@sb.path("data", "serve.pid")), "a running bot should record its pid"

    started = Time.now
    out, st = @sb.claw("up", "--telegram-only", "--if-not-running", env: env)
    assert st.success?, out
    assert_match(/already running/, out)
    assert_operator(Time.now - started, :<, 10, "the keeper must not sit there polling")

    Process.kill("TERM", pid)
    Process.wait2(pid)
    refute File.exist?(@sb.path("data", "serve.pid")), "the pidfile should not outlive the bot"
  ensure
    tg&.stop
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  # The bot gives up after repeated poll failures, and the service must not survive it: parked with
  # a dead bot, the keeper's "already running" check answers yes forever and the chat is silently
  # dead. That is what happened on the test bed under load, so the failure is now a non-zero exit.
  def test_service_mode_exits_when_the_bot_thread_dies
    tg = ClawTest::FakeTG.new(errors: { "getUpdates" => "this API never works" })
    env = { "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
            "CLAW_API_KEY" => "x", "CLAW_TG_MAX_FAILURES" => "1" }
    log = @sb.path("log", "botdeath.log")
    pid = Process.spawn(env, ClawTest::RUBY, @sb.path("bin/claw"), "up", "--telegram-only",
                        chdir: @sb.dir, in: File::NULL, out: log, err: log)
    _, status = Process.wait2(pid)

    refute status.success?, "a service with no bot must not exit zero"
    out = File.read(log)
    assert_match(/the bot stopped/, out)
    refute File.exist?(@sb.path("data", "serve.pid")), "and it must give the claim back"
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
    tg&.stop
  end

  # The bot was the whole job: a service that stays up with no bot is worse than one that stops
  # and says why, so this exits non-zero and prints the reason a supervisor can collect.
  def test_telegram_only_fails_loudly_when_the_bot_cannot_start
    tg = ClawTest::FakeTG.new(errors: { "getMe" => "Unauthorized" })
    out, st = @sb.claw("up", "--telegram-only",
                       env: { "CLAW_TELEGRAM_API_BASE" => tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
                              "CLAW_MODEL" => "test-model", "CLAW_BASE_URL" => "http://127.0.0.1:1/v1",
                              "CLAW_API_KEY" => "x" })
    refute st.success?, "a service whose only job is the bot must not exit 0 with no bot"
    assert_match(/Telegram is not available/, out)
    assert_match(/Unauthorized/, out)
  ensure
    tg&.stop
  end
end
