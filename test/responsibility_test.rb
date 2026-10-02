# frozen_string_literal: true
require_relative "test_helper"
require "time"
require_relative "../lib/work"
require_relative "../lib/responsibility"

# Standing commitments: an objective plus triggers, stored beside the work store.
#
# The pure parts (parsing and validating a trigger, matching an event to a responsibility)
# are tested in-process. Anything that writes -- the store, a timer's next slot, a file's
# fingerprint -- runs in a Sandbox, so this machine's own data/ is never touched.
class ResponsibilityTest < Minitest::Test
  include ClawTest

  R = RubyClaw::Responsibility

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
  end

  # ---- pure: reading a trigger spec ---------------------------------------------

  def test_a_trigger_spec_is_read_back_as_it_was_written
    assert_equal({ "type" => "timer", "spec" => "every 15m" }, R.parse_trigger("timer every 15m"))
    assert_equal({ "type" => "file.changed", "path" => "/etc/hosts" },
                 R.parse_trigger("file.changed /etc/hosts"))
    assert_equal({ "type" => "job.finished", "name" => "nightly" },
                 R.parse_trigger("job.finished nightly"))
    assert_equal({ "type" => "webhook", "source" => "github-push" },
                 R.parse_trigger("webhook github-push"))
    ws = R.parse_trigger("work.state DONE project=ops")
    assert_equal "DONE", ws["to"]
    assert_equal "ops", ws["project"]
  end

  def test_an_unreadable_trigger_says_what_it_accepts
    err = assert_raises(RubyClaw::Error) { R.parse_trigger("whenever you feel like it") }
    assert_match(/timer every 15m/, err.message)
  end

  def test_a_built_trigger_gets_an_id_and_a_first_slot
    t = R.build_trigger("timer every 15m", now: Time.now)
    assert_match(/\Atr-\h+\z/, t["id"])
    refute_nil t["next_run"], "a timer is due at once so the commitment proves itself"
    manual = R.build_trigger("work.state DONE", now: Time.now)
    assert_equal "DONE", manual["to"]
    refute manual.key?("next_run"), "only a timer has a slot"
    # a file trigger records no fingerprint yet: the first poll sets the baseline
    f = R.build_trigger("file.changed /tmp/x", now: Time.now)
    refute f.key?("fingerprint")
  end

  def test_a_bad_timer_spec_is_refused_before_anything_is_stored
    assert_raises(RubyClaw::Error) { R.build_trigger("timer someday") }
    assert_raises(RubyClaw::Error) { R.build_trigger("nonsense foo") }
  end

  # ---- pure: matching -----------------------------------------------------------

  # One event matches at most one responsibility, by the identity of the trigger that
  # fired -- so one event can create at most one task.
  def test_a_timer_event_matches_only_the_trigger_that_fired
    resp = { "id" => "r-1", "enabled" => true,
             "triggers" => [{ "id" => "tr-1", "type" => "timer", "enabled" => true }] }
    assert_equal "r-1", R.match({ "type" => "timer", "payload" => { "trigger_id" => "tr-1" } }, [resp]).first["id"]
    refute R.match({ "type" => "timer", "payload" => { "trigger_id" => "tr-2" } }, [resp])
  end

  def test_a_work_state_trigger_matches_only_its_state_and_project
    resp = { "id" => "r-1", "enabled" => true,
             "triggers" => [{ "id" => "tr-1", "type" => "work.state", "to" => "DONE", "project" => "ops" }] }
    assert R.match({ "type" => "work.state", "payload" => { "to" => "DONE", "project" => "ops" } }, [resp])
    refute R.match({ "type" => "work.state", "payload" => { "to" => "DONE", "project" => "web" } }, [resp])
    refute R.match({ "type" => "work.state", "payload" => { "to" => "FAILED", "project" => "ops" } }, [resp])
  end

  def test_a_paused_responsibility_matches_nothing
    resp = { "id" => "r-1", "enabled" => false,
             "triggers" => [{ "id" => "tr-1", "type" => "timer", "enabled" => true }] }
    refute R.match({ "type" => "timer", "payload" => { "trigger_id" => "tr-1" } }, [resp])
  end

  # ---- the store ----------------------------------------------------------------

  def test_a_responsibility_is_stored_with_its_triggers
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"
      r = RubyClaw::Responsibility.add(objective: "keep the deploy notes current", owner: "the operator",
                                       project: "ops", skill: "notes",
                                       triggers: ["timer every 15m", "work.state DONE project=ops"])
      puts "id=#{r['id']} trig=#{r['triggers'].size} auto=#{r['autonomy']} rep=#{r['reporting']}"
      puts "stored=#{RubyClaw::Work.responsibilities.size}"
    RB
    assert st.success?, out
    assert_match(/id=r-\h+ trig=2 auto=ask rep=on_completion/, out)
    assert_match(/stored=1/, out)
    assert @sb.exist?("data/responsibilities.json"), "a responsibility must be a file on disk"
  end

  def test_a_responsibility_with_no_trigger_is_refused
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "responsibility"
      begin
        RubyClaw::Responsibility.add(objective: "nobody will ever start this", triggers: [])
        puts "accepted (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/refused: a responsibility needs at least one trigger/, out)
    refute @sb.exist?("data/responsibilities.json")
  end

  def test_a_bad_autonomy_or_reporting_is_refused
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "responsibility"
      begin
        RubyClaw::Responsibility.add(objective: "x", triggers: ["timer hourly"], autonomy: "sometimes")
        puts "autonomy accepted (BAD)"
      rescue RubyClaw::Error => e
        puts "autonomy refused: #{e.message}"
      end
      begin
        RubyClaw::Responsibility.add(objective: "x", triggers: ["timer hourly"], reporting: "whenever")
        puts "reporting accepted (BAD)"
      rescue RubyClaw::Error => e
        puts "reporting refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/autonomy refused: autonomy is auto or ask/, out)
    assert_match(/reporting refused: reporting is on_change/, out)
  end

  # ---- the two sources the harness can actually see -----------------------------

  def test_a_timer_fires_once_and_advances_its_slot
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"
      t0 = Time.now
      RubyClaw::Responsibility.add(objective: "hourly report", triggers: ["timer hourly"], now: t0)
      first = RubyClaw::Responsibility.claim_timers(now: t0 + 1)
      second = RubyClaw::Responsibility.claim_timers(now: t0 + 2)
      puts "first=#{first.size} second=#{second.size} type=#{first.first['type']}"
      r = RubyClaw::Work.responsibilities.first
      puts "next_in_future=#{Time.parse(r['triggers'][0]['next_run']) > Time.now}"
    RB
    assert st.success?, out
    assert_match(/first=1 second=0 type=timer/, out, "a claimed slot must not fire twice")
    assert_match(/next_in_future=true/, out)
  end

  def test_a_changed_file_fires_after_a_baseline
    @sb.write("tracked.txt", "one")
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "responsibility"
      path = File.join(Dir.pwd, "tracked.txt")
      RubyClaw::Responsibility.add(objective: "watch the file", triggers: ["file.changed #{path}"])
      base = RubyClaw::Responsibility.poll_files
      File.write(path, "two, and longer")
      File.utime(Time.now + 5, Time.now + 5, path)
      changed = RubyClaw::Responsibility.poll_files
      again = RubyClaw::Responsibility.poll_files
      puts "baseline=#{base.size} changed=#{changed.size} again=#{again.size}"
      puts "path=#{changed.first && changed.first['payload']['path']}"
    RB
    assert st.success?, out
    assert_match(/baseline=0 changed=1 again=0/, out,
                 "the first poll sets a baseline; only a later change fires, once")
    assert_match(/path=.*tracked\.txt/, out)
  end

  # ---- the CLI ------------------------------------------------------------------

  def test_the_cli_adds_lists_and_shows_a_responsibility
    out, st = @sb.claw("resp", "add", "keep the notes current", "--trigger", "timer every 15m",
                       "--project", "ops", "--owner", "the operator")
    assert st.success?, out
    assert_match(/added r-\h+: keep the notes current/, out)
    assert_match(/timer every 15m/, out)
    id = out[/r-\h+/]

    listed, st2 = @sb.claw("resp")
    assert st2.success?, listed
    assert_match(/keep the notes current/, listed)
    assert_match(/autonomy ask/, listed)

    shown, st3 = @sb.claw("resp", "show", id)
    assert st3.success?, shown
    assert_match(/project=ops/, shown)
  end

  def test_the_cli_pauses_and_removes
    @sb.claw("resp", "add", "watch something", "--trigger", "timer hourly")
    id = @sb.read("data/responsibilities.json")[/r-\h+/]
    paused, st = @sb.claw("resp", "disable", id)
    assert st.success?, paused
    assert_match(/disabled/, paused)
    removed, st2 = @sb.claw("resp", "remove", id)
    assert st2.success?, removed
    assert_match(/removed/, removed)
  end
end
