# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/browser"

# Driving a real browser. These tests need a chromium binary *that can execute on this
# machine* and a few seconds each, so they skip (rather than fail) when it is missing or when
# the machine's own browser refuses to start -- measured on a Pi Zero 1 W (armv6), where
# Debian's Chromium exits with "lacks support for NEON SIMD extensions". That is the board's
# limitation, not a defect in this code, and the suite says so instead of reporting ten errors.
# They use a scratch profile and a local page: nothing here depends on the network or on
# anyone's data. Tests that need no browser at all live in browser_nobrowser_test.rb.
class BrowserTest < Minitest::Test
  PAGE = <<~HTML
    <!doctype html><html><head><meta charset="utf-8"><title>probe page</title></head><body>
      <h1 id="h">heading</h1>
      <button id="b" onclick="document.getElementById('h').textContent='clicked'">go</button>
      <input id="q">
      <script>document.getElementById("q").value = "typed by page";</script>
    </body></html>
  HTML

  def setup
    skip "no chromium on this machine" unless chromium?
    skip BrowserTestSkipReason.get if BrowserTestSkipReason.get    # probed once, see below
    @dir = Dir.mktmpdir("clawbrowser-")
    @page = File.join(@dir, "page.html")
    File.write(@page, PAGE)
    @b = RubyClaw::Browser.new(profile: File.join(@dir, "profile"))
  end

  def teardown
    @b&.stop!
    FileUtils.rm_rf(@dir) if @dir
  end

  # Starting a browser per test would cost a minute on a slow board, so this asks once per run
  # whether the machine's Chromium can actually start, and reports the answer it gave. Only a
  # "this binary cannot run here" answer is a skip; anything else is a real failure and lands.
  module BrowserTestSkipReason
    def self.get
      return @reason if @probed

      @probed = true
      dir = Dir.mktmpdir("clawprobe-")
      b = RubyClaw::Browser.new(profile: File.join(dir, "profile"))
      begin
        b.open("about:blank")
      rescue RubyClaw::Error => e
        raise unless e.message.match?(RubyClaw::Browser::CANNOT_RUN) || e.message.include?("cannot run here")

        @reason = "this machine's Chromium cannot run: #{e.message.lines.first.strip[0, 110]}"
      ensure
        b.stop!
        FileUtils.rm_rf(dir)
      end
      @reason
    end
  end

  def chromium?
    %w[chromium chromium-browser google-chrome google-chrome-stable].any? do |n|
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, n)) }
    end
  end

  def test_it_renders_javascript_and_answers_the_basic_questions
    @b.open("file://#{@page}")
    assert_equal "probe page", @b.title
    assert_includes @b.text, "heading"
    assert_includes @b.html, "probe page"
    assert_includes @b.url, "page.html"
    # the value was set by the page's own script: a plain HTTP fetch would not see it
    assert_equal "typed by page", @b.evaluate("document.getElementById('q').value")
  end

  def test_clicking_dispatches_a_real_mouse_event
    @b.open("file://#{@page}")
    result = @b.click("#b")
    assert_match(/clicked/, result)
    assert_equal "clicked", @b.evaluate("document.getElementById('h').textContent")
  end

  def test_typing_goes_into_the_focused_element
    @b.open("file://#{@page}")
    @b.type("#q", "hello from the harness")
    assert_equal "hello from the harness", @b.evaluate("document.getElementById('q').value")
  end

  # The whole reason to keep a browser alive instead of fetching: the page keeps its state
  # from one tool call to the next. That only works because the session is process-wide,
  # so this asserts the identity as well as the value.
  def test_the_page_keeps_its_state_between_calls
    old = ENV["CLAW_BROWSER_PROFILE"]
    ENV["CLAW_BROWSER_PROFILE"] = File.join(@dir, "session-profile")
    RubyClaw::Browser.close                       # start the shared session from scratch

    b = RubyClaw::Browser.session
    b.open("file://#{@page}")
    b.evaluate("window.__marker = 'still here'")

    assert_same b, RubyClaw::Browser.session, "the session must be the same browser"
    assert_equal "still here", RubyClaw::Browser.session.evaluate("window.__marker")
  ensure
    RubyClaw::Browser.close
    old.nil? ? ENV.delete("CLAW_BROWSER_PROFILE") : ENV["CLAW_BROWSER_PROFILE"] = old
  end

  def test_a_screenshot_lands_in_the_project_and_is_a_real_png
    @b.open("file://#{@page}")
    path = @b.screenshot.to_s.split(" (").first
    assert File.exist?(path), "screenshot should exist at #{path}"
    assert_operator File.size(path), :>, 1000
    assert_equal "\x89PNG".b, File.binread(path, 4), "it should be a PNG, not an empty file"
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_a_selector_that_matches_nothing_says_so_and_does_not_kill_the_session
    @b.open("file://#{@page}")
    err = assert_raises(RubyClaw::Error) { @b.click("#nope") }
    assert_match(/no element matches/, err.message)
    assert @b.alive?, "a bad selector must not take the browser down"
  end

  def test_javascript_that_throws_is_reported_not_swallowed
    @b.open("file://#{@page}")
    err = assert_raises(RubyClaw::Error) { @b.evaluate("throw new Error('boom')") }
    assert_match(/boom/, err.message)
  end

  # stop! used to signal and forget: the pid was dropped without waiting, so the next start
  # could find the old process still holding the profile's SingletonLock -- a real startup
  # failure -- and a crashed session left a chromium running with no handle on it.
  def test_stop_reaps_the_browser_and_a_restart_works
    @b.open("file://#{@page}")
    pid = @b.pid
    assert_operator pid, :>, 0

    @b.stop!
    refute @b.alive?
    assert_nil @b.pid
    gone = Timeout.timeout(10) do
      loop do
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          break true
        end
        sleep 0.1
      end
    end
    assert gone, "no chromium may outlive stop!"
    assert_includes @b.open("file://#{@page}"), "probe page", "a restart after a stop must work"
  end

  # The CDP endpoint is read out of chromium's own log, and the log used to be read whole:
  # after a reboot the first match was the *previous* run's line, so every call went to a
  # port nothing was listening on. out:/err: to a filename truncates the file at spawn.
  def test_a_stale_endpoint_from_a_previous_run_is_not_reused
    profile = File.join(@dir, "stalelog")
    FileUtils.mkdir_p(profile)
    File.write(File.join(profile, "chromium.log"),
               "DevTools listening on ws://127.0.0.1:9/devtools/browser/deadbeef\n")
    b = RubyClaw::Browser.new(profile: profile)
    b.open("file://#{@page}")
    assert b.alive?, "the browser must come up on its own endpoint, not the stale one"
    refute_includes b.instance_variable_get(:@endpoint).to_s, ":9/", "the stale URL must not be reused"
  ensure
    b&.stop!
  end

  # Two conversations, one socket. Without the lock, a reply is read by the wrong caller and
  # dropped, and its owner waits out a timeout for an answer that has already been consumed.
  # The Timeout is the point as much as the assertions: it fails instead of hanging if a
  # future edit makes a public method call another public method (the lock is not re-entrant).
  def test_two_threads_can_drive_the_browser
    @b.open("file://#{@page}")
    results = {}
    threads = { "one" => "window.__t1 = 'one'", "two" => "window.__t2 = 'two'" }.map do |key, js|
      Thread.new { results[key] = @b.evaluate(js) }
    end
    Timeout.timeout(60) { threads.each(&:join) }
    assert_equal %w[one two], results.values.map(&:to_s).sort
    assert_equal "one", @b.evaluate("window.__t1").to_s
    assert_equal "two", @b.evaluate("window.__t2").to_s
  end

end
