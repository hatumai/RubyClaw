# frozen_string_literal: true
require_relative "test_helper"

# preferences.md / memory.md / skills are how the harness keeps what it learns, so
# they are tested through the sandbox: real files, real CLI, no writes to the tree.
class NotesTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("notes")
  end

  def teardown
    @sb.cleanup
  end

  def test_ensure_creates_the_three_places
    out, st = @sb.ruby('require "boot"; RubyClaw::Notes.ensure!; puts Dir.children(RubyClaw::ROOT).sort.join(",")')
    assert st.success?, out
    assert_includes out, "preferences.md"
    assert_includes out, "memory.md"
    assert_includes out, "skills"
    assert_match(/# Preferences/, @sb.read("preferences.md"))
  end

  def test_append_records_a_dated_line
    out, st = @sb.ruby(<<~RB)
      require "boot"
      puts RubyClaw::Notes.append(:preference, "keep answers short")
      puts RubyClaw::Notes.read(:preference).lines.last
    RB
    assert st.success?, out
    assert_match(/preference: keep answers short/, out)
    assert_match(/- \d{4}-\d{2}-\d{2} keep answers short/, out)
  end

  def test_append_refuses_an_empty_note
    out, = @sb.ruby('require "boot"; begin; RubyClaw::Notes.append(:memory, "  "); rescue => e; puts e.class; end')
    assert_match(/RubyClaw::Error/, out)
  end

  def test_preferences_are_injected_and_labelled_as_overriding
    @sb.write("preferences.md", "# Preferences\n- 2026-01-01 never use emoji\n")
    out, = @sb.ruby('require "boot"; puts RubyClaw::Notes.inject')
    assert_match(/Preferences the user has stated/, out)
    assert_match(/override your defaults/, out)
    assert_match(/never use emoji/, out)
  end

  def test_shipped_and_instance_skills_are_both_injected
    @sb.write("memory.md", "# Memory\n- 2026-01-01 the printer is at .12\n")
    @sb.write("skills/backup.md", "Step 1: mount the disk.\n")
    @sb.write("instance/skills/tides.md", "Check the tide table first.\n")
    out, = @sb.ruby('require "boot"; puts RubyClaw::Notes.inject')
    assert_match(/the printer is at .12/, out)
    assert_match(/### backup/, out)
    assert_match(/Step 1: mount the disk/, out)
    assert_match(/### tides/, out)
    assert_match(/Check the tide table first/, out)
  end

  # Growth lives in instance/skills/ now, and an instance skill of the same name wins
  # over the shipped one -- the loader reads the shipped set first, then the instance's.
  def test_an_instance_skill_overrides_a_shipped_one_of_the_same_name
    @sb.write("skills/house_style.md", "shipped house style\n")
    @sb.write("instance/skills/house_style.md", "the instance's own house style\n")
    out, = @sb.ruby('require "boot"; puts RubyClaw::Notes.inject')
    assert_match(/the instance's own house style/, out)
    refute_match(/shipped house style/, out, "the instance's skill must win, not be shadowed")
    assert_equal 1, out.scan(/### house_style/).size, "and it appears once, not twice"
  end

  def test_a_runaway_file_is_truncated_with_a_notice
    @sb.write("memory.md", "# Memory\n#{"- " + ("x" * 100) + "\n" * 1}" * 200)
    out, = @sb.ruby('require "boot"; puts RubyClaw::Notes.inject.bytesize')
    assert_operator out.lines.first.to_i, :<, RubyClaw::Notes::MAX_INJECT + 1_000
    out2, = @sb.ruby('require "boot"; puts RubyClaw::Notes.inject')
    assert_match(/truncated; the file is longer/, out2)
  end

  def test_remember_tool_writes_a_preference_and_the_default_goes_to_memory
    out, st = @sb.ruby(<<~RB)
      require "boot"
      env = {"CLAW_NO_USAGE" => "1"}
      puts RubyClaw.call("remember", { "note" => "be terse", "kind" => "preference" })
      puts RubyClaw.call("remember", { "note" => "the host is a pi" })
      puts RubyClaw::Notes.read(:preference).lines.last
      puts RubyClaw::Notes.read(:memory).lines.last
    RB
    assert st.success?, out
    assert_match(/be terse/, out)
    assert_match(/the host is a pi/, out)
    assert_match(/preference: be terse — active from your next request/, out)
  end

  def test_cli_records_and_shows_notes
    out, st = @sb.claw("notes", "preference", "answer in one line")
    assert st.success?, out
    assert_match(/answer in one line/, @sb.read("preferences.md"))

    out2, = @sb.claw("notes")
    assert_match(/preferences\.md/, out2)
    assert_match(/answer in one line/, out2)
    assert_match(/skills\//, out2)
  end

  def test_cli_rejects_a_bad_kind
    out, st = @sb.claw("notes", "banana", "x")
    refute st.success?
    assert_match(/usage: claw notes/, out)
  end
end
