# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/browser"

# Everything about the browser tool that needs no browser, so it runs everywhere -- including
# on a board whose Chromium cannot start at all. The rest of the browser tests skip when the
# machine has no working browser; these must not, because they cover the paths that matter
# exactly when the browser misbehaves: the lock left by a crash, the tool's own bookkeeping,
# and a binary that exists but cannot execute (armv6 has no NEON; a container may be missing
# libraries; the file may be for another architecture).
class BrowserNoBrowserTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("clawbrowser-")
  end

  def teardown
    RubyClaw::Browser.close
    FileUtils.rm_rf(@dir)
  end

  # After a crash or a reboot, chromium finds its own lock file still in the profile and
  # refuses to start. That is the difference between coming back after a power cut and
  # needing someone to log in and delete a file.
  def test_a_stale_singleton_lock_is_cleared_and_a_live_one_is_respected
    profile = File.join(@dir, "locktest")
    FileUtils.mkdir_p(profile)
    b = RubyClaw::Browser.new(profile: profile)

    dead = File.join(profile, "SingletonLock")
    File.symlink("hostname-999999", dead)          # a pid that cannot be running
    b.send(:clear_stale_lock!)
    refute File.symlink?(dead), "a lock held by a dead process must be removed"

    File.symlink("hostname-#{Process.pid}", dead)
    b.send(:clear_stale_lock!)
    assert File.symlink?(dead), "a lock held by something alive must be left alone"
  end

  def test_the_tool_reports_whether_a_browser_is_running
    assert_includes RubyClaw.call("browser", { "action" => "status" }), "not running"
    assert_match(/unknown browser action/, RubyClaw.call("browser", { "action" => "fly" }))
  end

  # The measured case: Debian's Chromium on a Pi Zero 1 W, which exits at once rather than
  # render anything. Written as a two-line script so it runs on every machine, including one
  # with a perfectly good browser, and covers the same failure the real one produced.
  def fake_binary(body)
    path = File.join(@dir, "chromium")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def neon_binary
    fake_binary(%{echo "The hardware on this system lacks support for NEON SIMD extensions." >&2; exit 127})
  end

  def test_a_binary_that_cannot_run_is_reported_in_its_own_words
    b = RubyClaw::Browser.new(binary: neon_binary, profile: File.join(@dir, "p1"))
    err = assert_raises(RubyClaw::Error) { b.open("about:blank") }
    assert_match(/exited on startup/, err.message)
    assert_match(/NEON/, err.message, "the machine's own explanation has to reach the caller")
  end

  def test_a_known_doomed_binary_is_not_spawned_again_on_the_next_call
    b = RubyClaw::Browser.new(binary: neon_binary, profile: File.join(@dir, "p2"))
    assert_raises(RubyClaw::Error) { b.open("about:blank") }

    started = Time.now
    err = assert_raises(RubyClaw::Error) { b.open("about:blank") }
    elapsed = Time.now - started
    assert_match(/cannot run here/, err.message)
    assert_operator elapsed, :<, 1.0,
                    "a machine whose browser cannot start must not pay a spawn-and-wait per call"
  end

  def test_a_missing_binary_is_still_reported_as_missing
    b = RubyClaw::Browser.new(binary: File.join(@dir, "nope"), profile: File.join(@dir, "p3"))
    err = assert_raises(RubyClaw::Error) { b.open("about:blank") }
    assert_match(/no chromium binary found/, err.message)
  end

  def test_a_transient_failure_is_not_mistaken_for_a_broken_machine
    # A browser that dies for an ordinary reason (here: a bad flag) must NOT set the sticky
    # "cannot run here" answer -- that would poison every later call on a working machine.
    b = RubyClaw::Browser.new(binary: fake_binary(%{echo "unknown flag" >&2; exit 1}),
                              profile: File.join(@dir, "p4"))
    err = assert_raises(RubyClaw::Error) { b.open("about:blank") }
    refute_match(/cannot run here/, err.message)
    refute_match(/NEON/, err.message)
  end
end
