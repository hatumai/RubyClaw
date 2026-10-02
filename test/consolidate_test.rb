# frozen_string_literal: true
require_relative "test_helper"

# The audit that keeps the tool surface from rotting. The deterministic parts (what
# clusters, what the guards refuse, when no model is called at all) matter more than
# the model's judgement, so that is what is pinned here.
class ConsolidateTest < Minitest::Test
  include ClawTest

  TWIN_A = <<~'RB'
    RubyClaw.tool "twin_a", description: "Return the fixed phrase." do |a|
      "alpha beta gamma"
    end
  RB
  TWIN_B = <<~'RB'
    RubyClaw.tool "twin_b", description: "Return the fixed phrase." do |a|
      "alpha beta gamma"
    end
  RB

  def setup
    @sb = ClawTest::Sandbox.new("consolidate")
    @sb.git_init!
    @llm = FakeLLM.new
  end

  def teardown
    @sb.cleanup
    @llm.stop
  end

  def env = { "CLAW_BASE_URL" => @llm.base_url, "CLAW_API_KEY" => "x", "CLAW_MODEL" => "fake",
              "CLAW_NO_USAGE" => "1" }

  def twins!(args: nil, when_: nil)
    @sb.write("tools/twin_a.rb", TWIN_A)
    @sb.write("tools/twin_b.rb", TWIN_B)
    return unless args
    stamp = (when_ || (Time.now - (60 * 86_400))).iso8601
    rows = %w[twin_a twin_b].map do |t|
      JSON.generate({ "ts" => stamp, "tool" => t, "ms" => 1, "bytes" => 16, "ok" => true,
                      "args" => args })
    end
    @sb.write("log/usage.jsonl", rows.join($/) + $/)
    # The usage log is the evidence the guard and the replay read; a fixture that
    # writes one long mangled line would silently mean "never used".
    assert_equal 2, @sb.read("log/usage.jsonl").lines.size, "the usage log must be real lines"
  end

  # Replacing the endpoint inside a test must stop the previous one, or the suite
  # leaks a server per test.
  def llm_with(script)
    @llm.stop
    @llm = FakeLLM.new(script: script)
  end

  def plan(*ops) = FakeLLM.says(JSON.generate({ "ops" => ops }))

  # An idle audit must cost nothing: no clusters means no request at all.
  def test_nothing_to_consolidate_calls_no_model
    out, st = @sb.claw("consolidate", env: env)
    assert st.success?, out
    assert_match(/no candidate clusters/, out)
    assert_equal 0, @llm.call_count, "an audit with nothing to say must not spend tokens"
  end

  def test_two_tools_that_do_the_same_thing_are_put_to_the_model
    twins!
    llm_with([plan({ "action" => "keep", "tools" => %w[twin_a twin_b], "reason" => "leave it" })])
    out, st = @sb.claw("consolidate", env: env)
    assert st.success?, out
    assert_equal 1, @llm.call_count
    sent = JSON.parse(@llm.last_body["messages"].last["content"])
    assert_equal 1, sent["candidate_clusters"].size
    assert_includes sent["candidate_clusters"].first["tools"], "twin_a"
    assert_includes sent["candidate_clusters"].first["tools"], "twin_b"
    assert_match(/keep/, out)
    assert @sb.exist?("tools/twin_a.rb"), "a dry run changes nothing"
  end

  def test_merged_tool_replaces_both_originals_after_the_replay_passes
    twins!(args: { "x" => "1" })
    merged = <<~'RB'
      RubyClaw.tool "phrase", description: "Return the fixed phrase." do |a|
        "alpha beta gamma"
      end
    RB
    llm_with([plan({ "action" => "merge", "tools" => %w[twin_a twin_b], "name" => "phrase",
                     "source" => merged, "reason" => "identical behaviour" })])
    out, st = @sb.claw("consolidate", "--apply", env: env)
    assert st.success?, out
    assert_match(/merge/, out)
    assert @sb.exist?("instance/tools/phrase.rb"), "the merged tool is promoted into instance/"
    refute @sb.exist?("tools/twin_a.rb"), "the shipped originals should be retired"
    refute @sb.exist?("tools/twin_b.rb")
    commits = @sb.git_log
    assert(commits.any? { |m| m.include?("consolidate") && m.include?("phrase") },
           "the promotion is committed: #{commits.inspect}")
    retire = commits.find { |m| m.start_with?("consolidate(merge)") }
    assert retire, "the retirement is its own commit: #{commits.inspect}"
    assert_includes retire, "twin_a"
    assert_includes retire, "twin_b"
  end

  # A merge that would change what callers get must be refused, whatever the model says.
  def test_a_merge_that_changes_the_answer_is_refused
    twins!(args: { "x" => "1" })
    liar = <<~'RB'
      RubyClaw.tool "phrase", description: "Return the fixed phrase." do |a|
        "SOMETHING ELSE ENTIRELY"
      end
    RB
    llm_with([plan({ "action" => "merge", "tools" => %w[twin_a twin_b], "name" => "phrase",
                     "source" => liar, "reason" => "trust me" })])
    out, = @sb.claw("consolidate", "--apply", env: env)
    assert_match(/refus|replay|score|0\.0/i, out)
    refute @sb.exist?("instance/tools/phrase.rb"), "a failed replay must promote nothing"
    assert @sb.exist?("tools/twin_a.rb"), "and must retire nothing"
  end

  # A tool that was used today cannot be deleted, however the model argues.
  def test_deleting_a_recently_used_tool_is_refused
    twins!(args: { "x" => "1" }, when_: Time.now)
    llm_with([plan({ "action" => "delete", "tools" => %w[twin_b], "reason" => "redundant" })])
    out, st = @sb.claw("consolidate", "--apply", env: env)
    assert st.success?, out
    assert_match(/guard|#{RubyClaw::Consolidate::RECENT_DAYS}/, out)
    assert @sb.exist?("tools/twin_b.rb"), "the guard is what protects a live tool"
  end

  def test_the_inventory_covers_self_written_tools_and_leaves_builtins_alone
    twins!(args: { "x" => "1" })
    out, st = @sb.ruby(<<~RB)
      require "boot"; require "consolidate"
      inv = RubyClaw::Consolidate.inventory
      a = inv.find { |t| t["name"] == "twin_a" }
      puts JSON.generate({ "names" => inv.map { |t| t["name"] },
                           "calls" => inv.map { |t| [t["name"], t["calls"]] }.to_h,
                           "twin_score" => RubyClaw::Consolidate.score(a, inv.find { |t| t["name"] == "twin_b" }),
                           "floor" => RubyClaw::Consolidate::SIM_FLOOR })
    RB
    assert st.success?, out
    data = JSON.parse(out.lines.last)
    assert_includes data["names"], "sha256"
    assert_includes data["names"], "twin_a"
    refute_includes data["names"], "sh", "builtins are not candidates"
    assert_equal 1, data["calls"]["twin_a"]
    assert_operator data["twin_score"], :>=, data["floor"]
  end

  # Growth lands in instance/tools/ now, while the shipped tools/ set still exists and
  # is still audited. The inventory must cover both directories and say which is which,
  # so a shipped tool is never confused with the instance's own growth.
  def test_the_inventory_covers_shipped_and_instance_growth_and_says_which
    @sb.write("tools/shipped_thing.rb", TWIN_A.sub("twin_a", "shipped_thing"))
    @sb.write("instance/tools/mine_thing.rb", TWIN_B.sub("twin_b", "mine_thing"))
    out, st = @sb.ruby(<<~RB)
      require "boot"; require "consolidate"
      puts JSON.generate(RubyClaw::Consolidate.inventory.map { |t| [t["name"], t["location"], t["file"]] })
    RB
    assert st.success?, out
    rows = JSON.parse(out.lines.last).to_h { |name, loc, file| [name, [loc, file]] }
    assert_equal %w[shipped tools/shipped_thing.rb], rows["shipped_thing"],
                 "a shipped tool is inventoried, and said to be shipped"
    assert_equal %w[instance instance/tools/mine_thing.rb], rows["mine_thing"],
                 "the instance's own growth is inventoried too, and said to be its own"
    assert rows.key?("sha256"), "the shipped set is not lost"
  end
end
