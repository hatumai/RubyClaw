# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/notify"

# Stage D: the harness telling a person it needs one.
#
# Every test here drives the real path -- the heartbeat's pass, the CLI, the work store --
# against a fake Bot API in the test process, so nothing touches Telegram, the project's
# own data/ or this machine's crontab. The sandbox is where the stores live; the fake is
# where the messages land.
class NotifyTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("notify")
    @tg = FakeTG.new
    @env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
             "CLAW_TELEGRAM_ALLOWED" => "42" }
  end

  def teardown
    @sb&.cleanup
    @tg&.stop
  end

  # ---- the vocabulary and the routing rule (pure) ------------------------------

  def test_the_reporting_vocabulary_is_one_list_and_the_rule_is_data
    assert_equal RubyClaw::Responsibility::REPORTING, RubyClaw::Notify::REPORTING,
                 "one vocabulary, enforced where a responsibility is created and where it sends"
    assert_includes RubyClaw::Notify::REPORTING, "silent"

    # always / on_change admit everything; on_completion admits outcomes and anything
    # needing a person; on_failure only the bad half; digest is not a message; silent is
    # nothing. Written out so a change to the table is a change a reader can see.
    %w[always on_change].each do |r|
      %w[done failed blocked approval held].each { |c| assert RubyClaw::Notify.report?(c, r), "#{r} should admit #{c}" }
    end
    assert RubyClaw::Notify.report?("done", "on_completion")
    assert RubyClaw::Notify.report?("approval", "on_completion")
    refute RubyClaw::Notify.report?("done", "on_failure")
    assert RubyClaw::Notify.report?("failed", "on_failure")
    assert RubyClaw::Notify.report?("blocked", "on_failure")
    %w[silent never].each do |r|
      %w[done failed blocked approval held digest].each { |c| refute RubyClaw::Notify.report?(c, r), "#{r} must admit nothing" }
    end
    %w[done failed approval].each { |c| refute RubyClaw::Notify.report?(c, "daily_digest") }
    assert RubyClaw::Notify.report?("digest", "daily_digest")
    assert RubyClaw::Notify.valid_reporting?("silent")
    refute RubyClaw::Notify.valid_reporting?("whenever")
  end

  # ---- a parked approval reaches the allowlisted chat --------------------------

  def test_a_parked_approval_notifies_the_allowlisted_chat
    out, st = @sb.ruby(<<~'RB', env: @env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "send the report")
      W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
      r = RubyClaw::Heartbeat.pass
      ap = W.pending_approvals.first
      puts "parked=#{r['approvals'].size} sent=#{r['notify']['sent']} queued=#{r['notify']['queued']}"
      puts "approval=#{ap['id']}"
    RB
    assert st.success?, out
    assert_match(/parked=1 sent=1 queued=0/, out)

    assert_equal 1, @tg.sent.size, "one message for one parked approval"
    text = @tg.texts.first
    assert_equal 42, @tg.sent.first[:chat_id], "only the allowlisted chat is ever a destination"
    assert_match(/needs a person/, text)
    assert_match(/send the report/, text)
    assert_match(/claw work decide ap-\h+ granted/, text, "the exact command to grant it")
    assert_match(/claw work decide ap-\h+ denied/, text, "and to deny it")
  end

  # ---- nothing to report, nothing sent -----------------------------------------

  def test_nothing_to_report_sends_nothing
    out, st = @sb.claw("heartbeat", env: @env)
    assert st.success?, out
    assert_match(/told a person: sent 0/, out)
    assert_empty @tg.sent, "an idle pass must not invent a message"
  end

  def test_two_consecutive_passes_send_exactly_one_message
    @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "time"
      t = RubyClaw::Work.add_task(title: "ship it")
      RubyClaw::Work.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
    RB

    first, = @sb.claw("heartbeat", env: @env)
    second, = @sb.claw("heartbeat", env: @env)
    assert_equal 1, @tg.sent.size, "two passes over one pending approval: one message\n#{first}\n#{second}"
    assert_match(/sent 1/, first)
    assert_match(/sent 0/, second, "the second pass must not re-announce what is still pending")
  end

  # ---- one message per failure, not one per attempt -----------------------------

  def test_a_task_retried_to_failure_notifies_once
    out, st = @sb.ruby(<<~'RB', env: @env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "flaky deploy")
      W.update_task(t["id"], retry_limit: 3)
      3.times do
        W.set_state(t["id"], "WAITING") unless W.find_task(t["id"])["state"] == "WAITING"
        W.update_task(t["id"], retry_at: (Time.now - 1).utc.iso8601)
        RubyClaw::Heartbeat.pass
      end
      RubyClaw::Heartbeat.pass
      puts "state=#{W.find_task(t['id'])['state']} retries=#{W.events.count { |e| e['kind'] == 'task.retry' }}"
    RB
    assert st.success?, out
    assert_match(/state=FAILED/, out)
    assert_match(/retries=2/, out, "the task really was retried twice before it failed")
    assert_equal 1, @tg.sent.size, "a retried-then-failed task sends one message, not one per attempt"
    assert_match(/failed/, @tg.texts.first)
  end

  # ---- routing: a silent responsibility is silent -------------------------------

  def test_a_silent_responsibility_sends_nothing_for_its_work
    out, st = @sb.ruby(<<~'RB', env: @env)
      require "boot"; require "work"; require "responsibility"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      begin
        RubyClaw::Responsibility.add(objective: "x", triggers: ["webhook s"], reporting: "whenever")
        puts "bad reporting accepted (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message[0, 40]}"
      end
      quiet = RubyClaw::Responsibility.add(objective: "quiet watch", triggers: ["webhook quiet"],
                                           reporting: "silent")
      loud = RubyClaw::Responsibility.add(objective: "loud watch", triggers: ["webhook loud"],
                                          reporting: "always")
      a = W.add_task(title: "quiet work", responsibility_id: quiet["id"])
      b = W.add_task(title: "loud work", responsibility_id: loud["id"])
      [a, b].each { |t| W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601) }
      r = RubyClaw::Heartbeat.pass
      puts "sent=#{r['notify']['sent']} suppressed=#{r['notify']['suppressed']}"
    RB
    assert st.success?, out
    assert_match(/refused: reporting is on_change/, out, "the vocabulary is still enforced")
    assert_match(/sent=1 suppressed=1/, out)
    assert_equal 1, @tg.sent.size
    assert_match(/loud work/, @tg.texts.first)
    refute_match(/quiet work/, @tg.texts.first, "a silent responsibility's work is not announced")
  end

  # ---- destination: an unlisted chat is refused, none is invented ---------------

  def test_an_unlisted_chat_is_refused
    out, st = @sb.claw("notify", "test", "--chat", "999", env: @env)
    refute st.success?, out
    assert_match(/refusing to send/, out)
    assert_empty @tg.sent, "a chat that is not allowlisted is never a destination"

    ok, st2 = @sb.claw("notify", "test", env: @env)
    assert st2.success?, ok
    assert_equal 1, @tg.sent.size
    assert_match(/test notification/, @tg.texts.first)
    assert_equal 42, @tg.sent.first[:chat_id]
  end

  def test_with_no_allowlist_nothing_is_invented_and_it_says_so
    env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub" }
    out, st = @sb.ruby(<<~'RB', env: env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "send the report")
      W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
      r = RubyClaw::Heartbeat.pass
      puts "sent=#{r['notify']['sent']} no_destination=#{r['notify']['no_destination']} queued=#{r['notify']['queued']}"
    RB
    assert st.success?, out
    assert_match(/sent=0 no_destination=1 queued=0/, out)
    assert_empty @tg.sent

    view, = @sb.claw("notify", "queue", env: env)
    assert_match(/empty/, view)

    no, st2 = @sb.claw("notify", "test", env: env)
    refute st2.success?, no
    assert_match(/no destination configured/, no)
    assert_empty @tg.sent
  end

  # ---- headless: no token is not a crash ----------------------------------------

  def test_without_a_token_notifications_are_queued_not_shouted_into_the_void
    env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_ALLOWED" => "42" }
    out, st = @sb.ruby(<<~'RB', env: env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "send the report")
      W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
      r = RubyClaw::Heartbeat.pass
      puts "sent=#{r['notify']['sent']} failed=#{r['notify']['failed']} queued=#{r['notify']['queued']}"
    RB
    assert st.success?, out
    assert_match(/sent=0 failed=1 queued=1/, out)
    assert_empty @tg.sent

    q, st2 = @sb.claw("notify", "queue", env: env)
    assert st2.success?, q
    assert_match(/1 message\(s\) waiting/, q)
    assert_match(/BotFather|no Telegram token/, q, "the reason is the honest one: there is no token")
  end

  # ---- durability: a failed send is retried, and survives a restart -------------

  def test_a_send_that_fails_once_is_queued_and_then_delivered
    @tg.stop
    @tg = FakeTG.new(fail_sends: 1)
    env = @env.merge("CLAW_TELEGRAM_API_BASE" => @tg.base)

    # The first send fails. It must not be lost: it is queued, and the command says so.
    out, st = @sb.claw("notify", "test", env: env)
    refute st.success?, out
    assert_match(/queue depth: 1/, out)
    assert_empty @tg.sent

    q, = @sb.claw("notify", "queue", env: env)
    assert_match(/1 message\(s\) waiting/, q)
    assert_match(/simulated send failure/, q, "the queue records why it is waiting")

    # A separate process delivers it -- so this proves the queue survives a restart as
    # well as a retry.
    drain, st2 = @sb.claw("notify", "drain", env: env)
    assert st2.success?, drain
    assert_match(/1 sent/, drain)
    assert_equal 1, @tg.sent.size
    assert_match(/test notification/, @tg.texts.first)

    after, = @sb.claw("notify", "queue", env: env)
    assert_match(/empty/, after)
  end

  # ---- an approval message carries the buttons that decide it -------------------

  def test_a_parked_approval_message_carries_approve_and_deny_buttons
    out, st = @sb.ruby(<<~'RB', env: @env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "send the report")
      W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
      r = RubyClaw::Heartbeat.pass
      puts "sent=#{r['notify']['sent']}"
    RB
    assert st.success?, out
    assert_match(/sent=1/, out)

    kb = @tg.sent.first[:reply_markup]
    refute_nil kb, "a parked approval's message carries an inline keyboard"
    buttons = kb["inline_keyboard"].first
    labels = buttons.map { |b| b["text"] }
    assert_equal %w[Approve Deny], labels
    assert_match(/\Aapprove:ap-\h+\z/, buttons[0]["callback_data"])
    assert_match(/\Adeny:ap-\h+\z/, buttons[1]["callback_data"])
  end

  # A message with no approval behind it (a state change) carries no keyboard: the
  # buttons decide one specific approval, and there is none here.
  def test_an_ordinary_notification_carries_no_buttons
    out, st = @sb.ruby(<<~'RB', env: @env)
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "finish me")
      W.set_state(t["id"], "THINKING")
      W.set_state(t["id"], "DONE")
      r = RubyClaw::Heartbeat.pass
      puts "sent=#{r['notify']['sent']}"
    RB
    assert st.success?, out
    assert_match(/sent=1/, out)
    assert_nil @tg.sent.first[:reply_markup]
  end
end
