# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/update"

# Growth the harness writes for itself must live under instance/, which `claw update`
# refuses *by path* rather than by comparing contents -- while the shipped tools/ and
# skills/ directories keep working, keep loading, and stay visible. This is the
# structural guarantee: an update cannot reach the harness's own work even when the
# work is byte-identical to what upstream happened to sync last.
class InstanceGrowthTest < Minitest::Test
  include ClawTest

  GOOD = <<~'RB'
    RubyClaw.tool "t_grown", description: "A tool the harness wrote for itself." do |a|
      "grown: #{a['word']}"
    end
  RB

  def setup
    @sb = ClawTest::Sandbox.new("instance")
    @sb.git_init!
  end

  def teardown
    @sb.cleanup
  end

  def propose(name: "t_grown", source: GOOD, test: nil)
    out, st = @sb.ruby(<<~RB)
      require "boot"; require "selfwrite"
      puts RubyClaw::SelfWrite.propose(kind: "tool", name: #{name.dump}, source: #{source.dump},
                                       test: #{test.inspect}, reason: "test")
    RB
    [out.strip, st]
  end

  # The whole point: what the harness writes for itself lands in instance/, not in the
  # directory upstream also ships into.
  def test_growth_the_harness_writes_lands_in_instance
    out, st = propose(test: '{"word":"hi"}')
    assert st.success?, out
    assert @sb.exist?("instance/tools/t_grown.rb"), "growth belongs in instance/tools/"
    refute @sb.exist?("tools/t_grown.rb"), "not in the shipped directory"

    call, st2 = @sb.ruby('require "boot"; puts RubyClaw.call("t_grown", { "word" => "hi" })')
    assert st2.success?, call
    assert_equal "grown: hi", call.strip, "and it is loaded and callable"
  end

  # The shipped set still works: it loads, it answers, and it sits beside the instance's
  # own growth rather than being replaced by it.
  def test_the_shipped_tools_still_load_beside_the_instances_own
    propose(test: '{"word":"hi"}')
    out, st = @sb.ruby(<<~'RB')
      require "boot"
      puts RubyClaw.call("sha256", { "value" => "abc" })
      puts RubyClaw.tools["t_grown"] ? "grown-present" : "grown-missing"
    RB
    assert st.success?, out
    assert_match(/\A[0-9a-f]{64}\z/, out.lines.first.strip, "a shipped tool still answers")
    assert_includes out, "grown-present", "and the instance's own tool is loaded beside it"
  end

  # An instance tool of the same name wins over the shipped one, rather than being
  # skipped as an already-registered name (the loader reads the shipped set first).
  def test_an_instance_tool_of_the_same_name_wins_over_the_shipped_one
    @sb.write("instance/tools/now_iso.rb", <<~'RB')
      RubyClaw.tool("now_iso", description: "instance override", params: {}) { |_a| "instance-wins" }
    RB
    out, st = @sb.ruby('require "boot"; puts RubyClaw.call("now_iso", {})')
    assert st.success?, out
    assert_equal "instance-wins", out.strip, "the instance's file must override the shipped one"
  end

  # instance/ is the path an update refuses *before* it compares anything, which is what
  # makes the protection structural instead of detected. The end-to-end update behaviour
  # is pinned in update_test.rb; this pins the invariant the growth path depends on.
  def test_a_growth_path_is_one_an_update_refuses_by_path
    propose(test: '{"word":"hi"}')
    rel = "instance/tools/t_grown.rb"
    assert @sb.exist?(rel)
    assert(RubyClaw::Update::LOCAL_ONLY.any? { |p| rel == p || rel.start_with?(p) },
           "an update must refuse #{rel} by path, before any content comparison")
  end
end
