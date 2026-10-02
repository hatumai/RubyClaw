# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/term"

# The persistent shell. `sh` starts a process per call; this one keeps state, which is
# only useful if the state really is still there -- so that is what these test.
class TermTest < Minitest::Test
  def setup
    # A scratch script_dir: a call's command file must not be written into the project
    # this test is testing.
    @dir = Dir.mktmpdir("clawterm-")
    @t = RubyClaw::Term.new(cwd: RubyClaw::ROOT, script_dir: File.join(@dir, "term"))
  end

  def teardown
    @t.close
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_the_working_directory_and_exports_survive_between_calls
    out, status, = @t.run("cd /tmp && export CLAW_TERM_PROBE=kept && pwd")
    assert_equal 0, status
    assert_equal "/tmp", @t.cwd
    assert_includes out, "/tmp"

    out, status, cwd = @t.run('echo "var=$CLAW_TERM_PROBE dir=$PWD"')
    assert_equal 0, status
    assert_equal "/tmp", cwd
    assert_includes out, "var=kept dir=/tmp"
  end

  def test_the_exit_status_of_the_command_comes_back
    assert_equal 0, @t.run("true")[1]
    assert_equal 1, @t.run("false")[1]
    # A subshell, not `exit 3`: that would end the persistent shell itself (tested below)
    assert_equal 3, @t.run("(exit 3)")[1]
  end

  # Multi-line output used to be swallowed by a greedy regex in the marker parser: the
  # first line survived and everything after it was eaten as part of the marker match.
  def test_multi_line_output_is_returned_whole
    out, = @t.run("printf 'one\\ntwo\\nthree\\n'")
    assert_equal %w[one two three], out.strip.lines.map(&:strip)
  end

  def test_output_without_a_trailing_newline_is_returned
    out, status = @t.run("printf 'no newline'")
    assert_equal 0, status
    assert_includes out, "no newline"
  end

  # A command that outruns its deadline has to be killed -- and killing it costs the
  # session, which the caller must be told rather than silently handed a fresh shell.
  def test_a_timeout_kills_the_command_and_costs_the_session
    out, status, _cwd, timed_out, = @t.run("echo started; sleep 30", timeout: 2)
    assert timed_out, "the deadline must be reported"
    assert_nil status, "a killed command has no exit status"
    assert_includes out, "started"

    out, status, cwd, timed_out, restarted = @t.run("echo back")
    assert_equal 0, status
    assert_includes out, "back"
    assert restarted, "the session had to be restarted"
    refute timed_out
    assert_equal RubyClaw::ROOT, cwd, "a restarted shell starts in the project root"
  end

  # The command was the literal `exit`: no marker is coming, and waiting for one would
  # hang until the deadline.
  def test_a_command_that_ends_the_shell_returns_and_is_reported
    _out, status, _cwd, _to, _restarted = @t.run("exit 7")
    assert_nil status
    out, status, = @t.run("echo alive-again")
    assert_equal 0, status
    assert_includes out, "alive-again"
  end

  def test_a_command_that_prints_the_marker_text_is_not_mistaken_for_the_end
    # The marker carries a nonce per call, so a command that echoes the prefix cannot
    # look like the end of the command.
    out, status = @t.run("echo '#{RubyClaw::Term::MARK} 0 /not/the/end'; echo done")
    assert_equal 0, status
    assert_includes out, "not/the/end"
    assert_includes out, "done"
  end

  def test_binary_output_cannot_poison_the_result
    out, = @t.run("printf 'ok\\377\\376end\\n'")
    assert out.valid_encoding?, "output must be usable as UTF-8"
  end

  # A command with an unterminated quote used to swallow everything written after it --
  # including the marker line -- so the call burned its entire deadline and came back with
  # nothing, and the *session* (cd, exports) died with it. The command is sourced from a
  # file now, which contains a syntax error to that one command.
  def test_a_syntax_error_is_reported_and_does_not_cost_the_session
    @t.run("cd /tmp && export CLAW_TERM_PROBE=kept")
    out, status, _cwd, timed_out, restarted = @t.run(%q{echo "unterminated}, timeout: 15)
    refute timed_out, "a typo must not run out the clock"
    refute_equal 0, status.to_i
    assert_match(/unexpected EOF|syntax error/, out)

    out, status, cwd, = @t.run('echo "$CLAW_TERM_PROBE in $PWD"')
    assert_equal 0, status
    assert_includes out, "kept in /tmp"
    assert_equal "/tmp", cwd
    refute restarted, "the session must survive a typo in one command"
  end

  # MAX_BYTES was declared and never read, so a runaway command could grow the harness's
  # memory for as long as its deadline allowed. The cap keeps the head and the tail -- the
  # marker lives in the tail -- and says what it dropped.
  def test_a_spewing_command_is_capped_and_says_so
    out, status, = @t.run("head -c 3000000 /dev/zero | tr '\\0' A; echo TAIL-MARKER", timeout: 60)
    assert_equal 0, status
    assert_operator out.bytesize, :<, RubyClaw::Term::MAX_BYTES * 2
    assert_match(/output truncated/, out)
    assert_includes out, "TAIL-MARKER", "the end of the output is the part that matters"
  end

  # Under `claw up` a Telegram thread and the local prompt share this one session. Two
  # readers on one pipe pair hand one conversation the other's output: measured, one got
  # back an empty string while its text sat in the other's buffer.
  def test_two_conversations_do_not_get_each_others_output
    got = {}
    slow = Thread.new { got["A"] = @t.run("sleep 1.0; echo A-DONE", timeout: 30).first }
    sleep 0.2
    fast = Thread.new { got["B"] = @t.run("echo B-FAST", timeout: 30).first }
    Timeout.timeout(60) { [slow, fast].each(&:join) }
    assert_includes got["B"].to_s, "B-FAST", "the second caller must get its own output"
    refute_includes got["A"].to_s, "B-FAST", "and must not be handed the other caller's"
  end

  def test_no_command_file_is_left_behind
    @t.run("cd /tmp")
    @t.run("exit 0")            # the restart path has to clean up too
    @t.run("echo done")
    assert_empty Dir[File.join(@dir, "term", "cmd-*.sh")],
                 "a command file left behind is a command file left behind forever"
  end

  def test_it_does_not_leave_a_process_running_after_close
    t = RubyClaw::Term.new
    pid = t.instance_variable_get(:@pid)
    t.close
    refute t.alive?
    # TERM is asynchronous and close() reaps with a bounded join, so allow a moment
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
    assert gone, "the shell must not outlive close()"
  end
end
