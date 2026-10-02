# frozen_string_literal: true
require_relative "test_helper"

# The operator view. A dashboard is out of scope, so `claw status` is the substitute: one
# screen a person can read when they come back to a machine that has been running without
# them. This asserts it renders every category it claims to, in a length a person reads.
class StatusTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("status")
  end

  def teardown
    @sb&.cleanup
  end

  def seed
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "time"
      W = RubyClaw::Work
      r = W.add_task(title: "running now", project: "ops")
      W.set_state(r["id"], "WORKING")
      W.add_task(title: "queued work")
      f = W.add_task(title: "broke on deploy")
      W.set_state(f["id"], "WORKING")
      W.set_state(f["id"], "FAILED", note: "the deploy key expired")
      s = W.add_task(title: "stale deadline work")
      W.update_task(s["id"], deadline: (Time.now - 7200).utc.iso8601)
      a = W.add_task(title: "waiting on you")
      W.request_approval(task_id: a["id"], action: "shell.run")
      puts "seeded"
    RB
    assert st.success?, out
  end

  def test_the_view_renders_every_category_it_claims_to
    seed
    out, st = @sb.claw("status")
    assert st.success?, out

    assert_match(/WAITING ON YOU \(1\)/, out)
    assert_match(/shell\.run/, out)
    assert_match(/waiting on you/, out)
    assert_match(/claw work decide ap-\h+ granted/, out, "the exact command to grant")
    assert_match(/claw work decide ap-\h+ denied/, out, "and to deny")

    assert_match(%r{RUNNING / OPEN \(3\)}, out, "the running and queued work")
    assert_match(/WORKING/, out)
    assert_match(/queued work/, out)

    assert_match(/FAILED \(1\)/, out)
    assert_match(/the deploy key expired/, out, "what failed, and why")

    assert_match(%r{STALE / PAST DEADLINE \(1\)}, out)
    assert_match(/stale deadline work/, out)

    assert_match(/HARNESS/, out)
    assert_match(/bot +token set|bot +NO TOKEN/, out, "the bot's configuration")
    assert_match(/scheduler +\d+ job\(s\)/, out)
    assert_match(/heartbeat +no pass recorded|heartbeat +last pass/, out)
    assert_match(/notifications queue 0/, out)
    assert_match(/disk +/, out)

    assert_operator out.lines.size, :<=, 45, "the view has to be readable at a glance:\n#{out}"
  end

  def test_the_view_names_the_allowlist_when_there_is_one
    tg = FakeTG.new
    out, st = @sb.claw("status", env: { "CLAW_TELEGRAM_TOKEN" => "stub",
                                        "CLAW_TELEGRAM_ALLOWED" => "42",
                                        "CLAW_TELEGRAM_API_BASE" => tg.base })
    assert st.success?, out
    assert_match(/token set/, out)
    assert_match(/allowlist 42/, out)
  ensure
    tg&.stop
  end

  def test_the_view_reports_the_last_pass_and_the_queue
    out, st = @sb.claw("heartbeat")
    assert st.success?, out
    view, st2 = @sb.claw("status")
    assert st2.success?, view
    assert_match(/heartbeat +last pass/, view, "a pass that ran is visible afterwards")
    assert_match(/notifications queue 0/, view)
  end

  def test_the_view_is_honest_on_an_empty_machine
    out, st = @sb.claw("status")
    assert st.success?, out
    assert_match(%r{RUNNING / OPEN \(0\)}, out)
    assert_match(/HARNESS/, out)
    assert_match(/no pass recorded yet/, out)
    refute_match(/WAITING ON YOU/, out, "nothing is waiting, so nothing claims to be")
  end

  # `claw work` is the full store view; it has to carry the same decision command, or the
  # person reading it still has to guess.
  def test_claw_work_shows_the_exact_decision_command_and_a_passed_deadline
    seed
    view, st = @sb.claw("work")
    assert st.success?, view
    assert_match(/claw work decide ap-\h+ granted/, view)
    assert_match(/claw work decide ap-\h+ denied/, view)
    assert_match(/PAST DEADLINE/, view, "a deadline the heartbeat acts on is visible")
    assert_match(/the deploy key expired/, view)
  end
end
