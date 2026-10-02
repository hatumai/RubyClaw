# frozen_string_literal: true
require_relative "test_helper"

# The growth pipeline. Every kind goes through the same gate -- syntax, a throwaway
# child process, and a real call with real arguments -- and this is where the
# refusals are pinned, because a gate that lets something through is worse than no
# gate at all.
class SelfwriteTest < Minitest::Test
  include ClawTest

  GOOD = <<~'RB'
    RubyClaw.tool "t_echo", description: "Echo a word back." do |a|
      "echoed: #{a['word']}"
    end
  RB

  def setup
    @sb = ClawTest::Sandbox.new("selfwrite")
    @sb.git_init!
  end

  def teardown
    @sb.cleanup
  end

  def propose(kind: "tool", name: "t_echo", source: GOOD, test: nil, reason: "test",
              replace: false, dry_run: false)
    code = <<~RB
      require "boot"; require "selfwrite"
      puts RubyClaw::SelfWrite.propose(kind: #{kind.dump}, name: #{name.dump},
                                       source: #{source.dump}, test: #{test.inspect},
                                       reason: #{reason.dump}, replace: #{replace},
                                       dry_run: #{dry_run})
    RB
    out, st = @sb.ruby(code)
    [out.strip, st]
  end

  def test_a_dry_run_validates_in_a_child_and_writes_nothing
    out, st = propose(test: '{"word":"hi"}', dry_run: true)
    assert st.success?, out
    assert_match(/DRY RUN ok for tool `t_echo`/, out)
    refute @sb.exist?("instance/tools/t_echo.rb"), "a dry run must not promote"
  end

  def test_a_good_tool_is_promoted_committed_and_callable
    out, st = propose(test: '{"word":"hi"}')
    assert st.success?, out
    assert_match(/t_echo/, out)
    assert @sb.exist?("instance/tools/t_echo.rb"), "growth lands in the instance's own tools/"
    assert(@sb.git_log.any? { |m| m.include?("t_echo") }, "growth should be committed")

    call, st2 = @sb.ruby('require "boot"; puts RubyClaw.call("t_echo", { "word" => "hi" })')
    assert st2.success?, call
    assert_equal "echoed: hi", call.strip
  end

  def test_a_syntax_error_is_refused
    out, = propose(source: "RubyClaw.tool \"t_echo\", description: \"x\" do |a|\n")
    assert_match(/REJECTED tool `t_echo`: syntax error/, out)
    refute @sb.exist?("instance/tools/t_echo.rb")
  end

  def test_source_that_registers_nothing_is_refused
    out, = propose(source: "X = 1\n", test: "{}")
    assert_match(/REJECTED tool `t_echo`/, out)
    assert_match(/registered no tool/, out)
  end

  def test_a_parameter_without_a_type_is_refused_before_promotion
    out, = propose(source: <<~'RB')
      RubyClaw.tool "t_echo", description: "x", params: { "a" => { description: "no type" } } do |a|
        a["a"].to_s
      end
    RB
    assert_match(/REJECTED tool `t_echo`/, out)
    assert_match(/provider-shaped/, out)
  end

  # The regression the packaged-copy test found: intent right, placement wrong.
  def test_required_on_the_parameter_is_accepted_not_refused
    out, = propose(source: <<~'RB', test: '{"name":"x"}')
      RubyClaw.tool "t_echo", description: "x",
        params: { "name" => { type: "string", required: true } } do |a|
        a["name"].to_s
      end
    RB
    refute_match(/REJECTED/, out)
    assert @sb.exist?("instance/tools/t_echo.rb")
  end

  def test_a_tool_that_raises_on_its_own_test_arguments_is_refused
    out, = propose(source: "RubyClaw.tool \"t_echo\", description: \"x\" do |a|\n  raise \"nope\"\nend\n",
                   test: "{}")
    assert_match(/REJECTED tool `t_echo`/, out)
    assert_match(/nope/, out)
  end

  def test_a_bad_name_is_refused_and_logged
    out, = propose(name: "Echo Thing!", test: "{}")
    assert_match(/REJECTED/, out)
    assert_match(/snake_case/, out)
    log = @sb.read("log/evolution.jsonl").lines.map { |l| JSON.parse(l) }
    assert(log.any? { |e| e["reason"].to_s.include?("REJECTED") })
  end

  def test_replacing_an_existing_tool_needs_replacing
    out, = propose(test: '{"word":"one"}')
    refute_match(/REJECTED/, out)
    again, = propose(source: GOOD.sub("echoed:", "ECHO:"), test: '{"word":"two"}')
    assert_match(/REJECTED/, again)
    assert_match(/already registered|exists/, again)
    ok, = propose(source: GOOD.sub("echoed:", "ECHO:"), test: '{"word":"two"}', replace: true)
    refute_match(/REJECTED/, ok)
  end

  def test_a_skill_is_markdown_and_lands_in_skills
    out, st = propose(kind: "skill", name: "how_to_backup", source: "# Backup\nMount the disk first.\n")
    assert st.success?, out
    assert_match(/how_to_backup/, out)
    assert_equal "# Backup\nMount the disk first.\n", @sb.read("instance/skills/how_to_backup.md")
    refute @sb.exist?("skills/how_to_backup.md"), "a skill lands in the instance's own skills/"
  end

  def test_a_broken_core_patch_is_refused_and_the_previous_file_restored
    before = @sb.read("lib/notes.rb")
    out, = propose(kind: "core", name: "notes.rb", source: "raise 'boom'\n")
    assert_match(/REJECTED core `notes.rb`/, out)
    assert_equal before, @sb.read("lib/notes.rb"), "a bad core must never survive validation"
  end

  def test_a_good_core_patch_is_staged_committed_and_boots
    src = @sb.read("lib/notes.rb") + "\n# touched by the test\n"
    out, = propose(kind: "core", name: "notes.rb", source: src, reason: "add a comment")
    assert_match(/staged core patch to lib\/notes.rb/, out)
    assert_match(/touched by the test/, @sb.read("lib/notes.rb"))
    boots, st = @sb.claw("probe")
    assert st.success?, boots
    assert_match(/BOOT_OK/, boots)
  end

  def test_a_core_name_that_is_not_a_core_file_is_refused
    out, = propose(kind: "core", name: "brand_new.rb", source: "puts 1\n")
    assert_match(/REJECTED core `brand_new.rb`/, out)
  end

  def test_every_attempt_is_recorded_accepted_or_not
    propose(test: '{"word":"hi"}')
    propose(source: "X = 1\n")
    log = @sb.read("log/evolution.jsonl").lines.map { |l| JSON.parse(l) }
    assert(log.any? { |e| e["name"] == "t_echo" && !e["reason"].to_s.start_with?("REJECTED") })
    assert(log.any? { |e| e["reason"].to_s.start_with?("REJECTED") })
  end
end
