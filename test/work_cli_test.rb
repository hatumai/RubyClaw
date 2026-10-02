# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/work"

# The two ways a person or the model reaches the work store: the `claw work` CLI and the
# `work` tool. Both are deliberately thin -- the store is the substance, and it is tested in
# test/work_test.rb; this file proves the handles on it behave.
class WorkCliTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new
  end

  def teardown
    @sb&.cleanup
  end

  def test_the_cli_can_add_move_show_and_register
    out, st = @sb.claw("work", "add", "from the cli", "--project", "rubyclaw")
    assert st.success?, out
    assert_match(/queued t-\h+: from the cli/, out)
    id = out[/t-\h+/]

    moved, st2 = @sb.claw("work", "state", id, "working", "picked it up")
    assert st2.success?, moved
    assert_match(/#{id} is now WORKING/, moved)

    shown, st3 = @sb.claw("work", "show", id)
    assert st3.success?, shown
    assert_match(/WORKING/, shown)
    assert_match(/picked it up/, shown, "the history is reconstructable from the log")

    art, st4 = @sb.claw("work", "artifact", "report", "out.md", "data/out.md", id)
    assert st4.success?, art
    assert_match(/registered a-\h+: out\.md \(task #{id}\)/, art)

    listed, st5 = @sb.claw("work")
    assert st5.success?, listed
    assert_match(/out\.md/, listed)
    assert_match(/from the cli/, listed)
  end

  # The CLI and the tool write the same store: a task the model queued is the one `claw work`
  # shows, which is the whole point of putting it on disk rather than in the conversation.
  def test_the_cli_and_the_tool_share_one_store
    out, st = @sb.ruby(<<~'RB')
      require "boot"
      puts RubyClaw.call("work", { "action" => "add", "title" => "queued by the model" })
    RB
    assert st.success?, out

    view, st2 = @sb.claw("work")
    assert st2.success?, view
    assert_match(/queued by the model/, view)
  end

  def test_the_work_tool_can_add_list_and_register
    out, st = @sb.ruby(<<~'RB')
      require "boot"
      puts RubyClaw.call("work", { "action" => "add", "title" => "from the tool" })
      t = RubyClaw::Work.tasks.first
      puts RubyClaw.call("work", { "action" => "artifact", "type" => "file", "title" => "notes.txt",
                                    "location" => "data/notes.txt", "task_id" => t["id"] })
      puts RubyClaw.call("work", { "action" => "state", "id" => t["id"], "state" => "WORKING" })
      puts RubyClaw.call("work", { "action" => "list" })
      puts RubyClaw.call("work", { "action" => "nonsense" })
    RB
    assert st.success?, out
    assert_match(/queued t-\h+: from the tool/, out)
    assert_match(/registered a-\h+: file notes\.txt/, out)
    assert_match(/is now WORKING/, out)
    assert_match(/from the tool/, out)
    assert_match(/unknown work action/, out)
  end

  def test_the_work_tool_is_on_the_surface
    names = RubyClaw.schemas.map { |s| s[:function][:name] }
    assert_includes names, "work"
  end
end
