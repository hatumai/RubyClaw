# frozen_string_literal: true
require_relative "test_helper"
require "time"
require_relative "../lib/work"

# Operational state outside the chat.
#
# The pure parts (the transition rule, the age wording) are tested in-process. Anything
# that writes runs in a Sandbox, so this machine's own data/ is never touched -- and the
# two properties that matter most, "it is really on disk" and "two processes cannot corrupt
# it", are proved with real second processes rather than in-memory state.
class WorkTest < Minitest::Test
  include ClawTest

  W = RubyClaw::Work

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
  end

  # ---- the rule (pure) ------------------------------------------------------------

  def test_states_are_the_eight_named_ones
    assert_equal %w[QUEUED THINKING WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED], W::STATES
  end

  # Every one of the 64 (from, to) pairs, against the table itself: the rule is data, so it
  # can be exercised exhaustively without a process per pair.
  def test_every_illegal_transition_is_refused_by_the_rule
    W::STATES.each do |from|
      W::STATES.each do |to|
        assert_equal W::ALLOWED[from].include?(to), W.transition_allowed?(from, to),
                     "rule for #{from}->#{to}"
      end
    end
    # terminal states go nowhere: reopening is an explicit act, not a transition
    %w[DONE FAILED].each do |s|
      W::STATES.each { |to| refute W.transition_allowed?(s, to), "#{s} must not go to #{to}" }
    end
    # a task that was never started cannot be finished...
    refute W.transition_allowed?("QUEUED", "DONE")
    # ...but the ordinary moves are allowed
    assert W.transition_allowed?("QUEUED", "WORKING")
    assert W.transition_allowed?("WORKING", "DONE")
    assert W.transition_allowed?("BLOCKED", "QUEUED")
    assert W.transition_allowed?("WORKING", "NEEDS_APPROVAL")
  end

  def test_an_unknown_state_is_refused_by_name
    err = assert_raises(RubyClaw::Error) { W.normalize_state("sleeping") }
    assert_match(/QUEUED, THINKING/, err.message)
    assert_equal "WORKING", W.normalize_state(:working)
  end

  def test_ages_read_the_way_a_person_says_them
    assert_equal "45s", W.human_seconds(45)
    assert_equal "3m", W.human_seconds(180)
    assert_equal "2h4m", W.human_seconds((2 * 3600) + (4 * 60))
    assert_equal "1d2h", W.human_seconds(86_400 + (2 * 3600))
  end

  # ---- the store ------------------------------------------------------------------

  def test_a_store_round_trip
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      t = W.add_task(title: "ship section A", project: "rubyclaw", detail: "tasks, events, artifacts")
      puts "id=#{t['id']} state=#{t['state']}"
      t2 = W.set_state(t["id"], "working", note: "starting")
      puts "state2=#{t2['state']}"
      got = W.find_task(t["id"])
      puts "found=#{got['title']}|#{got['state']}|#{got['project']}|#{got['note']}"
    RB
    assert st.success?, out
    assert_match(/id=t-\h{8,} state=QUEUED/, out)
    assert_match(/state2=WORKING/, out)
    assert_match(/found=ship section A\|WORKING\|rubyclaw\|starting/, out)
    assert @sb.exist?("data/work.json"), "the task store must be a file on disk"
  end

  def test_a_task_needs_a_title
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      begin
        RubyClaw::Work.add_task(title: "  ")
        puts "no error (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/refused: a task needs a title/, out)
  end

  # The store is on disk, not in memory: a task written in one process is readable by a
  # fresh one, which is the whole difference between this and a conversation.
  def test_durability_across_a_restart
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      t = RubyClaw::Work.add_task(title: "survives a reboot")
      puts "wrote #{t['id']}"
    RB
    assert st.success?, out

    fresh, st2 = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      ts = RubyClaw::Work.tasks
      puts "n=#{ts.size} title=#{ts.first && ts.first['title']} state=#{ts.first && ts.first['state']}"
      puts "events=#{RubyClaw::Work.events.size}"
    RB
    assert st2.success?, fresh
    assert_match(/n=1 title=survives a reboot state=QUEUED/, fresh)
    assert_match(/events=1/, fresh, "the creation is in the event log too")
  end

  # Every illegal move is refused by set_state itself, not only by the table: a task is
  # seeded in each state and every target is attempted.
  def test_every_illegal_transition_is_refused_on_disk
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "json"
      W = RubyClaw::Work
      FileUtils.mkdir_p(File.dirname(W::TASKS))
      wrong = []
      W::STATES.each do |from|
        W::STATES.each do |to|
          File.write(W::TASKS, JSON.generate("tasks" => [{ "id" => "t-x", "title" => "x",
                                                           "state" => from, "updated" => Time.now.utc.iso8601,
                                                           "created" => Time.now.utc.iso8601 }]))
          legal = W::ALLOWED[from].include?(to)
          accepted = true
          begin
            W.set_state("t-x", to)
          rescue RubyClaw::Error
            accepted = false
          end
          wrong << "#{from}->#{to}" unless accepted == legal
        end
      end
      puts wrong.empty? ? "all #{W::STATES.size * W::STATES.size} pairs enforced" : "WRONG: #{wrong.join(', ')}"

      File.write(W::TASKS, JSON.generate("tasks" => [{ "id" => "t-d", "title" => "done", "state" => "DONE",
                                                       "updated" => Time.now.utc.iso8601 }]))
      begin
        W.set_state("t-d", "WORKING")
        puts "done->working allowed (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
      puts "reopened=#{W.reopen('t-d', note: 'second look')['state']}"
    RB
    assert st.success?, out
    assert_match(/all 64 pairs enforced/, out)
    assert_match(/refused: refusing to move task t-d from DONE to WORKING; use `reopen`/, out)
    assert_match(/reopened=QUEUED/, out)
  end

  def test_reopening_is_explicit_and_only_from_a_terminal_state
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      t = W.add_task(title: "still going")
      begin
        W.reopen(t["id"])
        puts "reopened a queued task (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/refused: task t-\h+ is QUEUED, not finished/, out)
  end

  # ---- artifacts ------------------------------------------------------------------

  def test_an_artifact_is_linked_to_its_task
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      t = W.add_task(title: "write the report", project: "rubyclaw")
      a = W.register_artifact(type: "report", title: "section-a.md", location: "data/section-a.md",
                              task_id: t["id"], project: "rubyclaw", created_by: "agent")
      puts "art=#{a['id']} task=#{a['task_id']} status=#{a['status']} v=#{a['version']} by=#{a['created_by']}"
      puts "linked=#{W.artifacts_for(t['id']).map { |x| x['title'] }.join(',')}"
      puts "all=#{W.artifacts.size}"
      begin
        W.register_artifact(type: "file", title: "orphan", location: "x", task_id: "t-nope")
        puts "linked to a missing task (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
      begin
        W.register_artifact(type: "file", title: "nowhere", location: "")
        puts "no location (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/task=t-\h+ status=draft v=1 by=agent/, out)
    assert_match(/linked=section-a\.md/, out)
    assert_match(/all=1/, out)
    assert_match(/refused: no task t-nope to link the artifact to/, out)
    assert_match(/refused: an artifact needs a location/, out)
  end

  # ---- the event log --------------------------------------------------------------

  def test_every_change_is_written_to_the_event_log
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      t = W.add_task(title: "trace me")
      W.set_state(t["id"], "WORKING")
      W.set_state(t["id"], "NEEDS_APPROVAL", note: "before sending")
      W.set_state(t["id"], "DONE", note: "approved")
      puts W.history(t["id"]).join("\n")
    RB
    assert st.success?, out
    assert_match(/task\.created\s+QUEUED/, out)
    assert_match(/task\.state\s+QUEUED->WORKING/, out)
    assert_match(/task\.state\s+WORKING->NEEDS_APPROVAL\s+before sending/, out)
    assert_match(/task\.state\s+NEEDS_APPROVAL->DONE\s+approved/, out)
    assert @sb.exist?("data/events.jsonl")
  end

  # A log a person edited by hand, with one bad line, must not blind the whole history.
  def test_a_malformed_event_line_is_skipped_not_fatal
    @sb.write("data/events.jsonl", "{\"ts\":\"2026-01-01T00:00:00Z\",\"kind\":\"task.created\",\"task_id\":\"t-1\"}\n" \
                                   "not json at all\n" \
                                   "{\"ts\":\"2026-01-01T00:01:00Z\",\"kind\":\"task.state\",\"task_id\":\"t-1\",\"from\":\"QUEUED\",\"to\":\"WORKING\"}\n")
    out, st = @sb.ruby('require "boot"; require "work"; puts RubyClaw::Work.history("t-1").size')
    assert st.success?, out
    assert_equal "2", out.strip
  end

  # ---- approvals ------------------------------------------------------------------

  def test_an_approval_parks_the_task_and_a_decision_moves_it
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      t = W.add_task(title: "publish")
      ap = W.request_approval(task_id: t["id"], action: "send to the mailing list")
      puts "state=#{W.find_task(t['id'])['state']} pending=#{W.pending_approvals.size}"
      W.decide_approval(ap["id"], "denied", by: "the operator", note: "not yet")
      puts "after_deny=#{W.find_task(t['id'])['state']} status=#{W.find_approval(ap['id'])['status']} by=#{W.find_approval(ap['id'])['decided_by']}"
      ap2 = W.request_approval(task_id: t["id"], action: "retry when ready")
      W.decide_approval(ap2["id"], "granted", by: "the operator")
      puts "after_grant=#{W.find_task(t['id'])['state']} pending=#{W.pending_approvals.size}"
      begin
        W.decide_approval(ap["id"], "granted")
        puts "decided twice (BAD)"
      rescue RubyClaw::Error => e
        puts "refused: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/state=NEEDS_APPROVAL pending=1/, out)
    assert_match(/after_deny=BLOCKED status=denied by=the operator/, out)
    assert_match(/after_grant=WORKING pending=0/, out)
    assert_match(/refused: approval ap-\h+ is already denied/, out)
  end

  # ---- two processes at once ------------------------------------------------------

  # Six writers, each its own process, two tasks each. Read-modify-write without the flock
  # loses tasks -- the last writer to save wins and the others vanish. The store must also
  # stay parseable and the log keep one well-formed line per event.
  def test_two_processes_writing_at_once_do_not_corrupt_the_store
    code = <<~'RB'
      require "boot"; require "work"
      W = RubyClaw::Work
      2.times { |i| W.add_task(title: "t-#{ARGV[0]}-#{i}") }
    RB
    pids = 6.times.map do |i|
      Process.spawn(ClawTest::RUBY, "-I", @sb.path("lib"), "-e", code, i.to_s,
                    chdir: @sb.dir, out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.wait(pid) }

    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"; require "json"
      W = RubyClaw::Work
      ts = W.tasks
      puts "tasks=#{ts.size} uniq_ids=#{ts.map { |t| t['id'] }.uniq.size}"
      raw = JSON.parse(File.read(W::TASKS))
      puts "valid=#{raw['tasks'].is_a?(Array)}"
      ev = File.readlines(W::EVENTS).map { |l| (JSON.parse(l) rescue nil) }
      puts "events=#{ev.size} unparseable=#{ev.count(&:nil?)}"
    RB
    assert st.success?, out
    assert_match(/tasks=12 uniq_ids=12/, out, "no task may be lost to a concurrent writer")
    assert_match(/valid=true/, out, "the store must still be JSON")
    assert_match(/events=12 unparseable=0/, out, "one well-formed log line per event, not interleaved")
  end

  # ---- the view -------------------------------------------------------------------

  def test_the_view_puts_what_is_stuck_first_and_groups_artifacts_by_task
    out, st = @sb.ruby(<<~'RB')
      require "boot"; require "work"
      W = RubyClaw::Work
      a = W.add_task(title: "stuck on the deploy key", project: "ops")
      W.set_state(a["id"], "WORKING")
      W.set_state(a["id"], "BLOCKED", note: "the key was rotated and nobody told us")
      b = W.add_task(title: "waiting for the approval")
      W.request_approval(task_id: b["id"], action: "send the newsletter")
      W.add_task(title: "not started yet")
      W.register_artifact(type: "report", title: "deploy-notes.md", location: "data/deploy-notes.md",
                          task_id: a["id"], status: "current", version: 2)
    RB
    assert st.success?, out

    view, st2 = @sb.claw("work")
    assert st2.success?, view
    assert_match(/RubyClaw work — 3 task\(s\)/, view)
    assert_match(/ATTENTION/, view)
    assert_match(/BLOCKED/, view)
    assert_match(/the key was rotated/, view, "the reason is shown, not just the state")
    assert_operator view.index("BLOCKED"), :<, view.index("not started yet"),
                    "what is stuck must come before what is merely queued"
    assert_operator view.index("NEEDS_APPROVAL"), :<, view.index("not started yet")
    assert_match(/ARTIFACTS/, view)
    assert_match(/stuck on the deploy key/, view, "the artifact is grouped under its task")
    assert_match(/deploy-notes\.md.*current v2/, view)
    assert_match(/send the newsletter/, view, "a pending approval is visible")
  end

  def test_the_view_says_nothing_yet_on_an_empty_store
    out, st = @sb.claw("work")
    assert st.success?, out
    assert_match(/nothing yet/, out)
    refute_match(/ATTENTION/, out)
  end

  def test_a_store_of_the_wrong_shape_says_so
    ["[]", "null", "\"tasks\"", "{\"tasks\": null}", "not json"].each do |bad|
      @sb.write("data/work.json", bad)
      out, st = @sb.ruby('require "boot"; require "work"; puts RubyClaw::Work.tasks.inspect')
      refute st.success?, "loading #{bad.inspect} must fail loudly"
      assert_match(/not a tasks list|not valid JSON/, out, "#{bad.inspect} must be explained")
      refute_match(/TypeError|NoMethodError/, out, "#{bad.inspect} must not surface a bare Ruby error")
    end
  end

  # ---- the store's view over the CLI and the tool are exercised in work_cli_test.rb, which
  # ships with them; the store itself is all this file needs.
end
