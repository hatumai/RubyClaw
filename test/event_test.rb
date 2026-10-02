# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/work"
require_relative "../lib/responsibility"
require_relative "../lib/event"

# Unified events: one shape for every trigger, one durable task per event.
#
# The property this file exists for is idempotence -- the same event never creates a second
# task -- and it is proved twice: through the inbox (submit, drain, replay) and at the
# binding layer (add_task_once, keyed on the task's own event_key), so it holds even after
# the ledger forgets. Everything that writes runs in a Sandbox.
class EventTest < Minitest::Test
  include ClawTest

  E = RubyClaw::Event

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
  end

  # ---- the key (pure) -----------------------------------------------------------

  def test_an_event_key_is_deterministic_in_the_sources_identifying_facts
    assert_equal "timer:tr-1:2026-01-01T00:00:00Z",
                 E.build_key("timer", { "trigger_id" => "tr-1", "slot" => "2026-01-01T00:00:00Z" })
    assert_equal "webhook:github-push:delivery-1", E.build_key("webhook", { "key" => "delivery-1",
                                                                            "source" => "github-push" })
    a = E.build_key("file.changed", { "trigger_id" => "tr", "fingerprint" => "10-100" })
    b = E.build_key("file.changed", { "trigger_id" => "tr", "fingerprint" => "11-101" })
    refute_equal a, b, "a different fingerprint is a different event"
    # with no caller key, a webhook's key is its body's digest -- same body, same event
    c = E.build_key("webhook", { "source" => "x", "ref" => "main" })
    assert_equal c, E.build_key("webhook", { "source" => "x", "ref" => "main" })
  end

  def test_an_unknown_event_type_is_refused
    assert_raises(RubyClaw::Error) { E.build_key("smoke-signal", {}) }
  end

  # ---- idempotence (the required property) --------------------------------------

  # The same event, submitted twice and replayed again after it was handled, creates
  # exactly one task. This is the analysis's hard requirement.
  def test_the_same_event_twice_creates_exactly_one_task
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"; require "event"
      RubyClaw::Responsibility.add(objective: "report on finished deploys",
                                   triggers: ["work.state DONE project=ops"])
      attrs = { "type" => "work.state",
                "payload" => { "task_id" => "t-1", "from" => "WORKING", "to" => "DONE",
                               "ts" => "2026-01-01T00:00:00Z", "project" => "ops" } }
      first = RubyClaw::Event.submit_attrs(attrs)
      second = RubyClaw::Event.submit_attrs(attrs)
      puts "first_dup=#{first['duplicate']} second_dup=#{second['duplicate']} pending=#{RubyClaw::Event.pending.size}"
      r1 = RubyClaw::Event.process
      puts "created=#{r1['created']} tasks=#{RubyClaw::Work.tasks.size}"
      # a full replay after the event was handled: still one task
      third = RubyClaw::Event.submit_attrs(attrs)
      r2 = RubyClaw::Event.process
      puts "replay_dup=#{third['duplicate']} after_replay=#{RubyClaw::Work.tasks.size} created2=#{r2['created']}"
      t = RubyClaw::Work.tasks.first
      puts "task_resp=#{t['responsibility_id']} key=#{t['event_key']}"
    RB
    assert st.success?, out
    assert_match(/first_dup=false second_dup=true pending=1/, out, "a replayed event is not queued twice")
    assert_match(/created=1 tasks=1/, out)
    assert_match(/replay_dup=true after_replay=1 created2=0/, out, "a replayed event must not make a second task")
    assert_match(/task_resp=r-\h+ key=work\.state:t-1:/, out)
  end

  # The binding guarantee: the dedupe and the create share one critical section, keyed on
  # the task's own event_key, so it holds however the event reached the layer.
  def test_add_task_once_is_the_binding_guarantee
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      a, ca = RubyClaw::Work.add_task_once(title: "x", event_key: "k1")
      b, cb = RubyClaw::Work.add_task_once(title: "x", event_key: "k1")
      puts "created=#{ca},#{cb} same=#{a['id'] == b['id']} tasks=#{RubyClaw::Work.tasks.size}"
      puts "found=#{RubyClaw::Work.task_for_event('k1')['id']}"
    RB
    assert st.success?, out
    assert_match(/created=true,false same=true tasks=1/, out)
    assert_match(/found=t-\h+/, out)
  end

  # ---- draining -----------------------------------------------------------------

  def test_an_event_with_no_matching_responsibility_is_ignored_not_stored_as_work
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "event"
      RubyClaw::Event.submit(type: "timer", payload: { "trigger_id" => "nobody", "slot" => "s1" })
      r = RubyClaw::Event.process
      puts "created=#{r['created']} ignored=#{r['ignored']} tasks=#{RubyClaw::Work.tasks.size}"
      puts "logged=#{RubyClaw::Work.events.any? { |e| e['kind'] == 'event.ignored' }}"
    RB
    assert st.success?, out
    assert_match(/created=0 ignored=1 tasks=0/, out)
    assert_match(/logged=true/, out, "an ignored event is still one line in the log")
  end

  # ---- scanning the harness's own transitions -----------------------------------

  def test_a_task_transition_is_scanned_into_an_event
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"; require "event"
      RubyClaw::Responsibility.add(objective: "report on done work", triggers: ["work.state DONE"])
      t = RubyClaw::Work.add_task(title: "ordinary work")
      RubyClaw::Work.set_state(t["id"], "WORKING")
      RubyClaw::Work.set_state(t["id"], "DONE")
      puts "scanned=#{RubyClaw::Event.scan_log}"
      r = RubyClaw::Event.process
      puts "created=#{r['created']} tasks=#{RubyClaw::Work.tasks.size}"
    RB
    assert st.success?, out
    assert_match(/created=1 tasks=2/, out, "the DONE transition becomes one task under the responsibility")
  end

  # A task created by an event must not itself fire a work.state trigger: a responsibility
  # watching DONE that also produced the task would create a task every time one finished.
  def test_an_event_created_task_does_not_feed_another_event
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"; require "event"
      RubyClaw::Responsibility.add(objective: "report on done work", triggers: ["work.state DONE"])
      t = RubyClaw::Work.add_task(title: "ordinary work")
      RubyClaw::Work.set_state(t["id"], "WORKING")
      RubyClaw::Work.set_state(t["id"], "DONE")
      RubyClaw::Event.scan_log
      RubyClaw::Event.process
      ev = RubyClaw::Work.tasks.find { |x| x["event_key"] }
      RubyClaw::Work.set_state(ev["id"], "WORKING")
      RubyClaw::Work.set_state(ev["id"], "DONE")
      puts "scanned_again=#{RubyClaw::Event.scan_log}"
      puts "tasks=#{RubyClaw::Work.tasks.size}"
    RB
    assert st.success?, out
    assert_match(/scanned_again=0/, out, "the responsibility's own task must not re-fire the trigger")
    assert_match(/tasks=2/, out)
  end

  # ---- the inbound seam ---------------------------------------------------------

  def test_the_event_cli_queues_and_dedupes
    out, st = @sb.claw("event", "post", "webhook", "--source", "github-push",
                       "--key", "delivery-1", "--payload", '{"ref":"main"}')
    assert st.success?, out
    assert_match(/queued ev-\h+ key=delivery-1/, out, "an explicit key is used as given")

    again, st2 = @sb.claw("event", "post", "webhook", "--source", "github-push",
                          "--key", "delivery-1", "--payload", '{"ref":"main"}')
    assert st2.success?, again
    assert_match(/duplicate/, again, "the same delivery must not be queued twice")
  end
end
