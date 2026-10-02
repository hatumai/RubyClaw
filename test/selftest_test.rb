# frozen_string_literal: true
require_relative "test_helper"
require "timeout"

# `claw selftest` makes real tool calls from the real tree to prove the surface reaches the
# world (`sh`, `http`). Those calls go through the autonomy gate, and the gate audited them
# into the project's own data/events.jsonl -- the real store the suite must never write. The
# audit is now skipped during a selftest (CLAW_SELFTEST, the same rule SelfWrite and Update
# keep); this drives the real entrypoint in the real tree and checks the store is untouched.
class SelftestTest < Minitest::Test
  include ClawTest

  def test_a_selftest_leaves_the_real_work_store_untouched
    before = ClawTest.real_state_snapshot
    # A bare invocation, as a person would run it: no permissive policy fixture, no selftest
    # flag, no inherited offset path. CLAW_NO_CRONTAB / CLAW_NO_USAGE stay inherited from the
    # suite so the child cannot touch the machine's crontab or the usage log.
    env = { "CLAW_SELFTEST" => nil, "CLAW_POLICY" => nil, "CLAW_TELEGRAM_OFFSET" => nil }
    out, = Timeout.timeout(300) do
      Open3.capture2e(env, ClawTest::RUBY, File.join(TEST_ROOT, "bin", "claw"), "selftest",
                      chdir: TEST_ROOT)
    end
    after = ClawTest.real_state_snapshot
    changed = ClawTest::REAL_STORES.select { |rel| before[rel] != after[rel] }
    assert_empty changed,
                 "a selftest wrote the project's own #{changed.join(', ')}; it must not touch data/"
    # The point is the store, not the network: the run must have happened, but a check that
    # needs the internet is allowed to fail without failing this test.
    assert_match(/checks passed/, out, "the selftest should still run: #{out[-400..]}")
  end
end
