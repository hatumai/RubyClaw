# frozen_string_literal: true
require_relative "test_helper"

# The suite must never touch the project's real runtime state.
#
# Two leaks got here before: a test that wrote the machine's real crontab, and a policy
# record that landed in data/events.jsonl against the real store. A test that needs the
# stores runs in a ClawTest::Sandbox, whose ROOT is its own tmpdir. This test states the
# rule where it can be read; test_helper's after_run hook enforces it at the end of the
# run, so a leak that happens after this test has already run still fails the suite.
class RealStateTest < Minitest::Test
  include ClawTest

  def test_the_suite_does_not_write_the_real_work_store
    now = ClawTest.real_state_snapshot
    changed = ClawTest::REAL_STORES.select { |rel| ClawTest::REAL_STATE_BASELINE[rel] != now[rel] }
    assert_empty changed,
                 "the suite wrote the project's own #{changed.join(', ')}; " \
                 "a test must run in a ClawTest::Sandbox, never against the real tree"
  end

  def test_the_snapshot_covers_every_work_store_the_suite_could_write
    %w[data/work.json data/events.jsonl data/approvals.json data/artifacts.json
       data/responsibilities.json data/pending-events.json data/notifications.json
       data/heartbeat.json].each do |rel|
      assert_includes ClawTest::REAL_STORES, rel
    end
  end
end
