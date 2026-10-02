# frozen_string_literal: true
require_relative "test_helper"

# The trigger half of Scout: a responsibility's saved query, polled by the heartbeat, whose
# findings become events, durable tasks and -- through lib/notify.rb, unchanged --
# notifications. The chain is the point: no new notification code exists for this.
#
# The whole chain runs in a Sandbox child process with Scout's provider pointed at a local
# fixture server, so it exercises the real heartbeat path without touching the internet and
# without touching the project's own stores.
class ScoutWiringTest < Minitest::Test
  include ClawTest

  R = RubyClaw::Responsibility

  def setup
    @web = FakeWeb.new(FakeWeb.scout_routes)
    @sb = ClawTest::Sandbox.new("scoutwiring")
  end

  def teardown
    @sb&.cleanup
    @web&.stop
  end

  # ---- the trigger vocabulary (in process, no store) -------------------------------

  def test_a_scout_trigger_carries_a_query_and_an_interval
    tr = R.build_trigger("scout ruby 3.5 release notes")
    assert_equal "scout", tr["type"]
    assert_equal "ruby 3.5 release notes", tr["query"]
    assert_equal R::SCOUT_EVERY, tr["every"], "6h by default, so nobody is hammered"
    assert tr["next_run"], "due now, like a timer: a new commitment proves itself next pass"
    assert_equal "scout ruby 3.5 release notes (every 6h)", R.describe_trigger(tr)
  end

  def test_a_scout_trigger_can_set_its_own_interval
    tr = R.build_trigger({ "type" => "scout", "query" => "x", "every" => "every 30m" })
    assert_equal "every 30m", tr["every"]
    assert_equal "scout x (every 30m)", R.describe_trigger(tr)
  end

  def test_a_scout_trigger_needs_a_query
    err = assert_raises(RubyClaw::Error) { R.build_trigger("scout") }
    assert_match(/needs a search query/, err.message)
  end

  def test_a_bad_interval_is_refused_rather_than_defaulted
    assert_raises(RubyClaw::Error) { R.build_trigger({ "type" => "scout", "query" => "x", "every" => "6h" }) }
  end

  # A scout finding is matched by trigger id, like a timer, and nothing else matches it.
  def test_a_scout_event_matches_its_trigger_by_id
    tr = R.build_trigger("scout x")
    assert R.trigger_matches?(tr, { "type" => "scout", "payload" => { "trigger_id" => tr["id"] } })
    refute R.trigger_matches?(tr, { "type" => "scout", "payload" => { "trigger_id" => "tr-other" } })
    refute R.trigger_matches?(tr, { "type" => "timer", "payload" => { "trigger_id" => tr["id"] } })
  end

  # One trigger, one page: the event key is the trigger and the page, so the same URL found
  # again is the same event.
  def test_the_event_key_is_the_trigger_and_the_page
    key = RubyClaw::Event.build_key("scout", { "trigger_id" => "tr-1", "fingerprint" => "abc123" })
    assert_equal "scout:tr-1:abc123", key
    refute_equal key, RubyClaw::Event.build_key("scout", { "trigger_id" => "tr-1", "fingerprint" => "def456" })
    assert_equal RubyClaw::Scout.fingerprint("https://example.com/x"),
                 RubyClaw::Scout.fingerprint("https://example.com/x")
  end

  # ---- the chain, end to end, in a sandbox child -----------------------------------

  def test_a_scout_finding_becomes_a_task_and_a_notification
    env = { "CLAW_SCOUT_DDG_URL" => "http://127.0.0.1:#{@web.port}/ddg",
            "CLAW_SCOUT_MIN_INTERVAL" => "0",
            # one fetch per run, so the second poll below can only work if a poll is itself a
            # run: the fetch budget is per pass, not per process
            "CLAW_SCOUT_MAX_FETCHES" => "1" }
    out, st = @sb.ruby(<<~'RB', env: env)
      require "boot"; require "work"; require "responsibility"; require "event"
      require "notify"; require "heartbeat"; require "scout"
      W = RubyClaw::Work
      resp = RubyClaw::Responsibility.add(objective: "watch for ruby stdlib news",
                                          triggers: ["scout ruby stdlib"], reporting: "on_completion",
                                          owner: "the operator")
      puts "trigger=#{RubyClaw::Responsibility.describe_trigger(resp['triggers'][0])}"
      report = RubyClaw::Heartbeat.pass
      puts "submitted=#{report['submitted']} created=#{report.dig('events', 'created')} model_calls=#{report['model_calls']}"
      tasks = W.tasks
      puts "tasks=#{tasks.size} states=#{tasks.map { |t| t['state'] }.uniq.inspect}"
      puts "linked=#{tasks.all? { |t| t['responsibility_id'] == resp['id'] }}"
      puts "detail_has_url=#{tasks.first['detail'].to_s.include?('docs.ruby-lang.org')}"
      matched = W.events.find { |e| e['kind'] == 'event.matched' }
      puts "event=#{matched['event']} key=#{matched['key']} resp=#{matched['responsibility_id']}"

      # a person does the work the finding asked for, and the EXISTING notify path tells
      # them about it -- there is no Scout notification code.
      t = tasks.first
      W.set_state(t["id"], "WORKING", note: "reading it")
      W.set_state(t["id"], "DONE", note: "summarised")
      scan = RubyClaw::Notify.scan(Time.now)
      puts "candidates=#{scan['candidates']} nodest=#{scan['no_destination']} suppressed=#{scan['suppressed']}"

      # the same page found again is not a second piece of work
      list = W.responsibilities
      list[0]["triggers"][0]["next_run"] = (Time.now - 60).utc.iso8601
      W.save_responsibilities(list)
      again = RubyClaw::Scout.poll_triggers
      dups = again.map { |a| RubyClaw::Event.submit_attrs(a)["duplicate"] }.uniq
      second = RubyClaw::Event.process
      puts "again=#{again.size} duplicate=#{dups.inspect} created2=#{second['created']} tasks2=#{W.tasks.size}"
    RB
    assert st.success?, out

    assert_match(/trigger=scout ruby stdlib \(every 6h\)/, out)
    # the fixture server serves two results, so one poll is two findings, two tasks
    assert_match(/submitted=2 created=2 model_calls=0/, out,
                 "a scout pass creates work without a model call of its own")
    assert_match(/tasks=2 states=\["QUEUED"\]/, out)
    assert_match(/linked=true/, out)
    assert_match(/detail_has_url=true/, out, "the task carries the page it came from")
    assert_match(/event=scout key=scout:tr-\w+:[0-9a-f]{16} resp=r-\w+/, out)
    assert_match(/candidates=1 nodest=1 suppressed=0/, out,
                 "the DONE task was routed to a person by the existing notification scan")
    assert_match(/again=2 duplicate=\[true\] created2=0 tasks2=2/, out,
                 "the same page again is not a second task")
  end

  # The tail of the chain, purely: the reporting policy the responsibility recorded is what
  # decides whether that notification is sent. (Routing itself is lib/notify.rb's own test.)
  def test_the_notification_respects_the_responsibilitys_reporting_policy
    assert RubyClaw::Notify.report?("done", "on_completion")
    refute RubyClaw::Notify.report?("done", "silent")
    refute RubyClaw::Notify.report?("done", "on_failure")
  end
end
