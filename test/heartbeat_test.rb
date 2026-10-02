# frozen_string_literal: true
require_relative "test_helper"
require "time"
require_relative "../lib/work"
require_relative "../lib/responsibility"
require_relative "../lib/event"
require_relative "../lib/heartbeat"

# The heartbeat: one pass that moves unattended work forward.
#
# The property the analysis insists on is that most passes make no model call at all, so
# that is tested first and with a real (stub) endpoint watching: the pass runs with a model
# configured and must not touch it. The rest -- a task from a trigger, a resume, a bounded
# retry, an approval parked for a person -- runs in a Sandbox.
class HeartbeatTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
    @llm&.stop
  end

  # ---- no model call ------------------------------------------------------------

  # A heartbeat with nothing to do makes no model call. A model endpoint is configured and
  # would answer if asked; the pass must not ask.
  def test_a_heartbeat_with_nothing_to_do_makes_no_model_call
    @llm = FakeLLM.new(script: [FakeLLM.says("you should never see this")])
    code = <<~'RB'
      require "boot"; require "heartbeat"; require "json"
      report = RubyClaw::Heartbeat.pass
      puts "model_calls=#{report['model_calls']}"
      puts "processed=#{report['events']['processed']} created=#{report['events']['created']}"
      puts "resumed=#{report['resumed'].size} retried=#{report['retried'].size}"
    RB
    env = { "CLAW_BASE_URL" => @llm.base_url, "CLAW_MODEL" => "fake", "CLAW_API_KEY" => "x" }
    out, st = @sb.ruby(code, env: env)
    assert st.success?, out
    assert_equal 0, @llm.call_count, "an idle heartbeat must not call a model"
    assert_match(/model_calls=0/, out)
    assert_match(/processed=0 created=0/, out)
  end

  # ---- a commitment becomes a task ----------------------------------------------

  def test_a_responsibility_creates_a_task_from_its_timer_trigger
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"; require "heartbeat"
      RubyClaw::Responsibility.add(objective: "keep the deploy notes current", project: "ops",
                                   triggers: ["timer every 15m"])
      report = RubyClaw::Heartbeat.pass
      puts "created=#{report['events']['created']} tasks=#{RubyClaw::Work.tasks.size}"
      t = RubyClaw::Work.tasks.first
      puts "resp=#{t['responsibility_id']} state=#{t['state']} project=#{t['project']}"
      again = RubyClaw::Heartbeat.pass
      puts "again=#{again['events']['created']} tasks=#{RubyClaw::Work.tasks.size}"
    RB
    assert st.success?, out
    assert_match(/created=1 tasks=1/, out)
    assert_match(/resp=r-\h+ state=QUEUED project=ops/, out)
    assert_match(/again=0 tasks=1/, out, "one slot makes one task, not one per pass")
  end

  def test_a_webhook_event_creates_a_task_when_a_responsibility_matches
    @sb.claw("resp", "add", "handle the push", "--trigger", "webhook github-push")
    @sb.claw("event", "post", "webhook", "--source", "github-push", "--key", "delivery-9",
             "--payload", '{"ref":"main"}')
    out, st = @sb.claw("heartbeat")
    assert st.success?, out
    assert_match(/1 created task/, out)
    view, = @sb.claw("work")
    assert_match(/handle the push/, view, "the responsibility's task is real work in the store")
  end

  # ---- resume, retry, expire ----------------------------------------------------

  def test_a_waiting_task_resumes_when_its_dependency_completes
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "heartbeat"
      W = RubyClaw::Work
      dep = W.add_task(title: "the thing it waits for")
      t = W.add_task(title: "the waiting work")
      W.set_state(t["id"], "WAITING")
      W.update_task(t["id"], depends_on: dep["id"])
      before = RubyClaw::Heartbeat.pass
      puts "before=#{W.find_task(t['id'])['state']} resumed=#{before['resumed'].size}"
      W.set_state(dep["id"], "WORKING")
      W.set_state(dep["id"], "DONE")
      after = RubyClaw::Heartbeat.pass
      puts "after=#{W.find_task(t['id'])['state']} resumed=#{after['resumed'].include?(t['id'])}"
    RB
    assert st.success?, out
    assert_match(/before=WAITING resumed=0/, out)
    assert_match(/after=WORKING resumed=true/, out, "a satisfied dependency must resume the task")
  end

  def test_a_failing_task_is_retried_a_bounded_number_of_times_then_failed
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "flaky")
      W.update_task(t["id"], retry_limit: 3)
      3.times do |i|
        cur = W.find_task(t["id"])
        W.set_state(cur["id"], "BLOCKED") unless cur["state"] == "BLOCKED"
        W.update_task(t["id"], retry_at: (Time.now - 1).utc.iso8601)
        RubyClaw::Heartbeat.pass
        puts "attempt#{i + 1}=#{W.find_task(t['id'])['state']}/#{W.find_task(t['id'])['attempts']}"
      end
      RubyClaw::Heartbeat.pass
      puts "final=#{W.find_task(t['id'])['state']}/#{W.find_task(t['id'])['attempts']}"
      puts "retries=#{W.events.count { |e| e['kind'] == 'task.retry' }}"
      puts "exhausted=#{W.events.any? { |e| e['kind'] == 'task.retries_exhausted' }}"
    RB
    assert st.success?, out
    assert_match(/attempt1=QUEUED\/1/, out, "the first failed attempt is retried")
    assert_match(/attempt2=QUEUED\/2/, out, "so is the second")
    assert_match(/attempt3=FAILED\/3/, out, "the third exhausts the limit and marks it FAILED")
    assert_match(/final=FAILED\/3/, out, "a failed task is not retried forever")
    assert_match(/retries=2/, out)
    assert_match(/exhausted=true/, out)
  end

  # ---- a person is needed -------------------------------------------------------

  def test_a_task_past_its_deadline_parks_an_approval_and_does_not_proceed
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "heartbeat"; require "time"
      W = RubyClaw::Work
      t = W.add_task(title: "send the report")
      W.update_task(t["id"], deadline: (Time.now - 60).utc.iso8601)
      report = RubyClaw::Heartbeat.pass
      puts "state=#{W.find_task(t['id'])['state']} parked=#{report['approvals'].include?(t['id'])}"
      ap = W.pending_approvals.first
      puts "approval=#{ap['action']} task=#{ap['task_id']}"
      RubyClaw::Heartbeat.pass
      puts "pending=#{W.pending_approvals.size}"
    RB
    assert st.success?, out
    assert_match(/state=NEEDS_APPROVAL parked=true/, out, "the heartbeat parks a person's input")
    assert_match(/approval=task is past its deadline: send the report/, out)
    assert_match(/pending=1/, out, "one deadline, one approval -- not one per pass")
  end

  def test_a_failed_dependency_parks_an_approval_rather_than_guessing
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "heartbeat"
      W = RubyClaw::Work
      dep = W.add_task(title: "the thing that fails")
      t = W.add_task(title: "blocked on the failure")
      W.set_state(t["id"], "WAITING")
      W.update_task(t["id"], depends_on: dep["id"])
      W.set_state(dep["id"], "WORKING")
      W.set_state(dep["id"], "FAILED")
      RubyClaw::Heartbeat.pass
      puts "state=#{W.find_task(t['id'])['state']}"
      puts "approval=#{W.pending_approvals.first['action']}"
    RB
    assert st.success?, out
    assert_match(/state=NEEDS_APPROVAL/, out)
    assert_match(/approval=dependency t-\h+ FAILED/, out)
  end

  def test_the_render_says_what_a_pass_did
    out, st = @sb.claw("heartbeat")
    assert st.success?, out
    assert_match(/heartbeat \d/, out)
    assert_match(/model calls: 0/, out)
  end
end
