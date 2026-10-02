# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/policy"

# The autonomy policy: ACTION -> auto | ask | block | human_only.
#
# The pure half (default-deny, the four decisions, rule order, the explicit tool ->
# action table, and the shipped file's own contents) is exercised in-process, without a
# store. The half that reaches the dispatch path -- a held action that does not run, a
# grant consumed by exactly one call, the refusal wording, and the event log -- runs in a
# Sandbox, so this machine's own data/ is never touched.
class PolicyTest < Minitest::Test
  include ClawTest

  P = RubyClaw::Policy

  def setup
    @tmp = Dir.mktmpdir("clawpolicy-")
    @n = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    @sb&.cleanup
    @llm&.stop
    @web&.stop
    RubyClaw::Policy.reset!
  end

  # A copy of the tree to call tools in: a held action parks an approval in the store,
  # so the real data/ must never be the one it writes to.
  def sandbox
    @sb ||= ClawTest::Sandbox.new("policy")
  end

  # A child that uses its sandbox's own policy.yml (the shipped one, or a fixture
  # written first), rather than the suite's permissive pin.
  SANDBOX_POLICY = { "CLAW_POLICY" => nil }.freeze

  # A throwaway policy file, pointed at for the duration of the block.
  def with_policy(body)
    @n += 1
    path = File.join(@tmp, "policy-#{@n}.yml")
    File.write(path, body)
    with_env("CLAW_POLICY" => path) do
      RubyClaw::Policy.reset!
      yield path
    end
  end

  def shipped
    RubyClaw::Policy.load_config(File.join(TEST_ROOT, "policy.yml"))
  end

  # ---- default-deny (the safety property) ----------------------------------------

  def test_an_action_that_matches_no_rule_is_ask_not_auto
    with_policy("default: ask\nrules:\n  - match: files.*\n    policy: auto\n") do
      assert_equal "auto", P.decide("files.read")["policy"]
      assert_equal "ask", P.decide("shell.run")["policy"], "a rule covers files.* only"
      assert_equal "ask", P.decide("tool.something_new")["policy"], "an unlisted tool is denied"
    end
  end

  # A missing or unreadable file must fail closed. If it failed open, deleting the file
  # would silently grant the agent everything.
  def test_a_missing_policy_file_fails_closed
    with_env("CLAW_POLICY" => File.join(@tmp, "nope.yml")) do
      RubyClaw::Policy.reset!
      assert_equal "ask", P.decide("files.read")["policy"]
      assert_equal "ask", P.decide("shell.run")["policy"]
    end
  end

  def test_an_empty_policy_file_is_default_deny
    with_policy("") do
      assert_equal "ask", P.decide("anything")["policy"]
    end
  end

  # ---- the four decisions ---------------------------------------------------------

  def test_each_of_the_four_decisions_is_read_from_the_file
    with_policy(<<~YAML) do
      default: ask
      rules:
        - match: files.read
          policy: auto
        - match: files.write
          policy: ask
        - match: shell.run
          policy: block
          note: no shell on this box
        - match: credentials.*
          policy: human_only
    YAML
      assert_equal "auto", P.decide("files.read")["policy"]
      assert_equal "ask", P.decide("files.write")["policy"]
      assert_equal "block", P.decide("shell.run")["policy"]
      assert_equal "human_only", P.decide("credentials.read")["policy"]
      # ...and the reason is carried with the decision
      assert_equal ["shell.run"], P.decide("shell.run")["matched"]
      assert_equal "no shell on this box", P.decide("shell.run")["note"]
    end
  end

  # Order is the operator's: a specific rule above a broad one wins.
  def test_the_first_matching_rule_wins
    with_policy(<<~YAML) do
      default: ask
      rules:
        - match: shell.*
          policy: block
        - match: shell.run
          policy: auto
    YAML
      assert_equal "block", P.decide("shell.run")["policy"], "the broad rule came first"
    end

    with_policy(<<~YAML) do
      default: ask
      rules:
        - match: shell.run
          policy: auto
        - match: shell.*
          policy: block
    YAML
      assert_equal "auto", P.decide("shell.run")["policy"], "the specific rule came first"
    end
  end

  def test_a_mistyped_policy_name_is_refused_not_ignored
    with_policy("default: ask\nrules:\n  - match: shell.run\n    policy: blok\n") do
      err = assert_raises(RubyClaw::Error) { P.decide("shell.run") }
      assert_match(/unknown policy "blok"/, err.message)
      assert_match(/auto \| ask \| block \| human_only/, err.message)
    end
  end

  def test_a_broken_policy_file_is_refused_rather_than_run_through
    with_policy("default: ask\nrules: [unclosed\n") do
      assert_raises(RubyClaw::Error) { P.decide("files.read") }
    end
  end

  def test_a_rule_needs_a_match_and_a_policy
    with_policy("default: ask\nrules:\n  - policy: auto\n") do
      assert_match(/needs a non-empty `match:`/, assert_raises(RubyClaw::Error) { P.decide("x") }.message)
    end
  end

  # ---- the tool -> action mapping -------------------------------------------------

  def test_every_builtin_has_an_explicit_action_name
    mapping = {
      "sh" => "shell.run", "term" => "shell.run", "read_file" => "files.read",
      "write_file" => "files.write", "grep" => "files.search", "http" => "http.get",
      "remember" => "notes.write", "browser" => "browser.drive",
      "schedule" => "schedule.manage", "extend" => "selfwrite.tool", "work" => "work.manage"
    }
    mapping.each { |tool, action| assert_equal action, P.action_for(tool, {}), tool }
    # the mapping is the whole surface this layer pretends to know: a tool not listed
    # above is named, not guessed, and lands on the default (ask)
    assert_equal "tool.sha256", P.action_for("sha256", {})
    assert_equal "tool.now_iso", P.action_for("now_iso", {})
    assert_equal "tool.feed_items", P.action_for("feed_items", {})
  end

  # The three refinements read one coarse argument -- never content. Where the analysis
  # draws a line (read vs send), the action name carries it.
  def test_http_is_a_read_only_for_get_and_head
    assert_equal "http.get", P.action_for("http", { "method" => "GET" })
    assert_equal "http.get", P.action_for("http", { "method" => "head" })
    assert_equal "http.get", P.action_for("http", {}), "no method means GET"
    assert_equal "http.send", P.action_for("http", { "method" => "POST" })
    assert_equal "http.send", P.action_for("http", { "method" => "DELETE" })
  end

  def test_extend_names_the_kind_it_would_write
    assert_equal "selfwrite.tool", P.action_for("extend", { "kind" => "tool" })
    assert_equal "selfwrite.skill", P.action_for("extend", { "kind" => "skill" })
    assert_equal "selfwrite.core", P.action_for("extend", { "kind" => "core" })
    assert_equal "selfwrite.tool", P.action_for("extend", {}), "an unknown kind is not trusted further"
  end

  # The agent must never decide its own approval, so work.decide is its own action.
  def test_work_decide_is_its_own_action
    assert_equal "work.decide", P.action_for("work", { "action" => "decide" })
    assert_equal "work.manage", P.action_for("work", { "action" => "add" })
    assert_equal "work.manage", P.action_for("work", {})
  end

  def test_the_mapping_tolerates_symbol_keys
    assert_equal "http.send", P.action_for("http", { method: "POST" })
    assert_equal "work.decide", P.action_for("work", { action: "decide" })
  end

  # ---- the shipped policy is the one thing a new install runs ---------------------

  def test_the_shipped_policy_is_default_deny
    assert_equal "ask", shipped["default"]
  end

  def test_the_shipped_policy_reads_and_writes_and_runs_as_the_analysis_says
    cfg = shipped
    # reading is auto: it changes nothing
    %w[files.read files.search http.get notes.write work.manage scout.search scout.read].each do |action|
      assert_equal "auto", P.decide(action, cfg)["policy"], action
    end
    # the actions the analysis names as needing a person ask
    %w[files.write files.delete shell.run http.send purchase browser.drive
       schedule.manage selfwrite.tool selfwrite.skill selfwrite.core].each do |action|
      assert_equal "ask", P.decide(action, cfg)["policy"], action
    end
    # and the two that can never be granted
    assert_equal "human_only", P.decide("credentials.read", cfg)["policy"]
    assert_equal "human_only", P.decide("work.decide", cfg)["policy"],
                 "the agent must not be able to decide its own approvals"
  end

  def test_the_shipped_policy_denies_by_default
    cfg = shipped
    assert_equal "ask", P.decide("tool.sha256", cfg)["policy"]
    assert_equal "ask", P.decide("shell.rm_rf", cfg)["policy"]
    assert_equal "ask", P.decide("anything.at.all", cfg)["policy"]
  end

  # ---- the approval channel is autonomous, explicitly ---------------------------

  # The harness's own Telegram sends must never be parked: the message that carries the
  # Approve button would itself be waiting for a person, and nobody could ever grant the
  # action it is about. The autonomy is stated as a rule, not inherited from the default.
  def test_telegram_send_is_auto_by_an_explicit_rule_so_the_channel_cannot_deadlock
    assert_equal "telegram.send", P.action_for("telegram", {})

    cfg = shipped
    d = P.decide("telegram.send", cfg)
    assert_equal "auto", d["policy"], "the harness's own approval channel must stay open"
    assert_equal "rule", d["source"], "stated as a rule, not left to the default"
    assert_match(/deadlock/, d["note"].to_s, "and the reason is written down")

    # ...but a Telegram action nobody named is still default-deny.
    assert_equal "ask", P.decide("telegram.other", cfg)["policy"]
  end

  # ---- Scout: two read actions, and no writable one -------------------------------

  # The mapping names the two reads. There is deliberately no third Scout action: a POST
  # from Scout is not "ask", it does not exist, so no rule and no grant can reach one.
  def test_scout_has_two_read_actions_and_no_writable_one
    assert_equal "scout.search", P.action_for("scout_search", {})
    assert_equal "scout.read", P.action_for("scout_read", {})
    assert_equal %w[scout.read scout.search], P::TOOL_ACTIONS.values.grep(/\Ascout\./).sort

    cfg = shipped
    assert_equal "auto", P.decide("scout.search", cfg)["policy"]
    assert_equal "auto", P.decide("scout.read", cfg)["policy"]
    # ...and a Scout action that would write is not granted by anything: default-deny.
    %w[scout.send scout.write scout.post scout.delete].each do |action|
      assert_equal "ask", P.decide(action, cfg)["policy"], action
    end
  end

  # The code half of the same claim: the verb table Scout actually uses has one entry, and
  # it is a read. (test/scout_test.rb asserts the requests that reached a server.)
  def test_scouts_verb_table_is_a_single_read
    assert_equal %w[GET], RubyClaw::Scout::ALLOWED_METHODS
    assert_raises(RubyClaw::Error) { RubyClaw::Scout.guard_method!("POST") }
  end

  # Through the dispatch path, with the SHIPPED policy: a Scout read runs unattended
  # instead of parking an approval, and it parks nothing behind it. The provider is a local
  # fixture server, so no test needs the internet.
  def test_a_scout_read_runs_unattended_under_the_shipped_policy
    @web = FakeWeb.new(FakeWeb.scout_routes)
    env = SANDBOX_POLICY.merge("CLAW_SCOUT_DDG_URL" => "http://127.0.0.1:#{@web.port}/ddg",
                               "CLAW_SCOUT_MIN_INTERVAL" => "0")
    out, st = sandbox.ruby(<<~'RB', env: env)
      require "boot"; require "work"
      puts RubyClaw.call("scout_search", { "query" => "ruby stdlib" })
      puts "pending=#{RubyClaw::Work.pending_approvals.size} tasks=#{RubyClaw::Work.tasks.size}"
      puts RubyClaw.call("scout_read", { "url" => "http://127.0.0.1:0/nope" })[0, 120]
    RB
    assert st.success?, out
    assert_match(/UNTRUSTED WEB CONTENT/, out, "the search ran, unattended")
    assert_match(/Net::HTTP/, out)
    assert_match(/pending=0 tasks=0/, out, "an auto read parks no approval and makes no task")
    assert_match(/ERROR \(RubyClaw::Error\): scout_read/, out,
                 "a read that cannot be made is an error string, not a crash")
  end

  def test_the_policy_file_is_the_projects_unless_overridden
    with_env("CLAW_POLICY" => nil) do
      assert_equal File.join(TEST_ROOT, "policy.yml"), P.path
    end
    with_env("CLAW_POLICY" => "/etc/other.yml") do
      assert_equal "/etc/other.yml", P.path
    end
  end

  # ---- through the dispatch path, in a sandbox -----------------------------------
  # Everything above decides; everything below is the decision reaching lib/registry.rb
  # `call` before a tool runs, against the real store.

  def test_an_ask_action_does_not_run_and_leaves_a_pending_approval
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"; require "work"
      r = RubyClaw.call("write_file", { "path" => "held.txt", "content" => "x" })
      puts "say=#{r}"
      puts "exists=#{File.exist?('held.txt')}"
      puts "pending=#{RubyClaw::Work.pending_approvals.map { |a| a['action'] }.inspect}"
      puts "task=#{RubyClaw::Work.tasks.map { |t| t['state'] }.inspect}"
    RB
    assert st.success?, out
    assert_match(/WAITING ON A HUMAN/, out, "the model must be told it is waiting, not that it failed")
    assert_match(/`files\.write` is `ask` \(rule `files\.write`/, out)
    assert_match(/parked in the work store/, out)
    assert_match(/exists=false/, out, "an `ask` action must NOT run")
    assert_match(/pending=\["files\.write"\]/, out)
    assert_match(/task=\["NEEDS_APPROVAL"\]/, out)
    refute sandbox.exist?("held.txt")
  end

  # A grant authorises the action ONCE: the call that uses it consumes it, so a second
  # identical call must ask again rather than ride the same authorisation.
  def test_a_granted_approval_runs_the_action_once_and_not_twice
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"; require "work"
      W = RubyClaw::Work
      r1 = RubyClaw.call("write_file", { "path" => "one.txt", "content" => "one" })
      puts "held1=#{r1.include?('WAITING ON A HUMAN')} exists1=#{File.exist?('one.txt')}"
      ap = W.pending_approvals.find { |a| a["action"] == "files.write" }
      W.decide_approval(ap["id"], "granted", by: "the operator")
      r2 = RubyClaw.call("write_file", { "path" => "one.txt", "content" => "one" })
      puts "ran2=#{r2.include?('wrote 3 bytes')} granted=#{W.events.any? { |e| e['kind'] == 'policy.granted' }}"
      r3 = RubyClaw.call("write_file", { "path" => "one.txt", "content" => "TWO" })
      puts "after_third=#{File.read('one.txt')} held3=#{r3.include?('WAITING ON A HUMAN')}"
      puts "consumed=#{W.approvals.count { |a| a['consumed'] }} " \
           "consumed_event=#{W.events.any? { |e| e['kind'] == 'approval.consumed' }} " \
           "pending=#{W.pending_approvals.size}"
    RB
    assert st.success?, out
    assert_match(/held1=true exists1=false/, out)
    assert_match(/ran2=true granted=true/, out, "a granted approval lets the same call run")
    assert_match(/after_third=one held3=true/, out, "the third call must not ride the consumed grant")
    assert_match(/consumed=1 consumed_event=true pending=1/, out)
    assert_equal "one", sandbox.read("one.txt")
  end

  def test_a_denied_approval_leaves_the_action_undone
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"; require "work"
      W = RubyClaw::Work
      RubyClaw.call("write_file", { "path" => "no.txt", "content" => "x" })
      ap = W.pending_approvals.first
      W.decide_approval(ap["id"], "denied", by: "the operator", note: "not this")
      r = RubyClaw.call("write_file", { "path" => "no.txt", "content" => "x" })
      puts "held=#{r.include?('WAITING ON A HUMAN')} exists=#{File.exist?('no.txt')}"
      puts "task=#{W.find_task(ap['task_id'])['state']}"
    RB
    assert st.success?, out
    assert_match(/held=true exists=false/, out, "a denial leaves the action undone")
    assert_match(/task=BLOCKED/, out)
  end

  # human_only and block both refuse, and no approval can grant either -- so they are
  # tested differently: no grant is even offered.
  def test_human_only_refuses_and_names_the_rule
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"; require "work"
      r = RubyClaw.call("work", { "action" => "decide", "id" => "ap-x", "decision" => "granted" })
      puts r
      puts "approvals=#{RubyClaw::Work.approvals.size}"
    RB
    assert st.success?, out
    assert_match(/HUMAN ONLY/, out)
    assert_match(/rule `work\.decide`/, out, "it says which rule matched")
    assert_match(/no approval can grant it/, out, "and that a grant cannot unlock it")
    assert_match(/approvals=0/, out, "nothing was decided")
  end

  def test_block_refuses_runs_nothing_and_says_why
    sandbox.write("policy.yml", <<~YAML)
      default: ask
      rules:
        - match: shell.*
          policy: block
          note: no shell on this box
    YAML
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"
      puts RubyClaw.call("sh", { "command" => "touch blocked.txt" })
      puts "exists=#{File.exist?('blocked.txt')}"
    RB
    assert st.success?, out
    assert_match(/BLOCKED BY POLICY/, out)
    assert_match(/rule `shell\.\*`: no shell on this box/, out)
    assert_match(/no approval can grant it/, out)
    assert_match(/exists=false/, out, "a blocked command must not run")
  end

  def test_an_unlisted_tool_is_held_by_default_deny
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"
      puts RubyClaw.call("sha256", { "value" => "abc" })
    RB
    assert st.success?, out
    assert_match(/WAITING ON A HUMAN/, out)
    assert_match(/no rule matched, and the policy default-denies/, out)
  end

  # A policy file that cannot be read must stop the action, not wave it through.
  def test_a_broken_policy_file_stops_the_action
    sandbox.write("policy.yml", "default: ask\nrules: [oops\n")
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"
      puts RubyClaw.call("write_file", { "path" => "boom.txt", "content" => "x" })
      puts "exists=#{File.exist?('boom.txt')}"
    RB
    assert st.success?, out
    assert_match(/ERROR \(RubyClaw::Error\)/, out)
    assert_match(/not valid YAML/, out)
    assert_match(/exists=false/, out)
  end

  # The harness's own replay (child_ab.rb) says so and is exempt; the model never can.
  def test_an_internal_call_is_exempt
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"
      puts RubyClaw.call("write_file", { "path" => "internal.txt", "content" => "x" }, internal: true)
      puts "exists=#{File.exist?('internal.txt')}"
    RB
    assert st.success?, out
    assert_match(/wrote 1 bytes/, out)
    assert_match(/exists=true/, out)
  end

  # ---- the audit trail -----------------------------------------------------------

  def test_every_decision_is_written_to_the_event_log
    out, st = sandbox.ruby(<<~'RB', env: SANDBOX_POLICY)
      require "boot"; require "work"
      W = RubyClaw::Work
      RubyClaw.call("read_file", { "path" => "config.yml" })                 # auto, by rule
      RubyClaw.call("write_file", { "path" => "x.txt", "content" => "x" })   # ask
      RubyClaw.call("work", { "action" => "decide", "id" => "nope" })        # human_only
      puts W.events.map { |e| e["kind"] }.tally.inspect
      puts "auto_action=#{W.events.find { |e| e['kind'] == 'policy.auto' }['action']}"
      puts "ask_action=#{W.events.find { |e| e['kind'] == 'policy.ask' }['action']}"
    RB
    assert st.success?, out
    assert_match(/"policy\.auto"\s*=>\s*1/, out)
    assert_match(/"policy\.ask"\s*=>\s*1/, out)
    assert_match(/"policy\.human_only"\s*=>\s*1/, out)
    assert_match(/auto_action=files\.read/, out)
    assert_match(/ask_action=files\.write/, out)
    assert_equal true, File.exist?(sandbox.path("data", "events.jsonl"))
  end

  # ---- the model loop is the path this protects ----------------------------------

  def test_the_model_loop_is_gated_by_the_policy
    @llm = FakeLLM.new(script: [FakeLLM.calls("write_file", path: "from-model.txt", content: "x"),
                                FakeLLM.says("done")])
    code = <<~'RB'
      require "boot"; require "harness"; require "work"
      h = RubyClaw::Harness.new(quiet: true)
      puts "answer=#{h.run('write a file')}"
      puts "pending=#{RubyClaw::Work.pending_approvals.map { |a| a['action'] }.inspect}"
    RB
    env = SANDBOX_POLICY.merge("CLAW_BASE_URL" => @llm.base_url, "CLAW_MODEL" => "fake",
                               "CLAW_API_KEY" => "x")
    out, st = sandbox.ruby(code, env: env)
    assert st.success?, out
    assert_match(/answer=done/, out, "the conversation still finishes")
    assert_match(/pending=\["files\.write"\]/, out, "the model's write was held, not run")
    refute sandbox.exist?("from-model.txt")
    msg = @llm.requests.last[:body]["messages"].find { |m| m["role"] == "tool" }
    assert_equal "write_file", msg["name"]
    assert_match(/WAITING ON A HUMAN/, msg["content"], "the model hears that it is waiting on a person")
  end
end
