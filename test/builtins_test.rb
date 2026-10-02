# frozen_string_literal: true
require_relative "test_helper"

# Builtins are exercised through the registry, exactly as the model reaches them.
class BuiltinsTest < Minitest::Test
  include ClawTest

  def setup
    @tmp = Dir.mktmpdir("clawbi-")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_sh_reports_output_and_exit_status
    out = RubyClaw.call("sh", { "command" => "echo hello; exit 3" })
    assert_match(/hello/, out)
    assert_match(/\[exit 3\]/, out)
  end

  def test_sh_times_out_instead_of_hanging
    out = RubyClaw.run_shell("sleep 30", timeout: 1)
    assert_match(/TIMEOUT after 1s/, out)
  end

  def test_read_file_pages_with_offset_and_limit
    f = File.join(@tmp, "x.txt")
    File.write(f, (1..10).map { |i| "line#{i}" }.join("\n"))
    out = RubyClaw.call("read_file", { "path" => f, "offset" => 3, "limit" => 2 })
    assert_match(/3\|line3/, out)
    assert_match(/4\|line4/, out)
    refute_match(/line5/, out)
  end

  def test_read_file_missing_file_is_an_error_string
    out = RubyClaw.call("read_file", { "path" => "#{@tmp}/nope" })
    assert_match(/ERROR \(RubyClaw::Error\): no such file/, out)
  end

  # write_file is confined to the project, so its refusals are what an in-process test
  # can check; the happy path (parents created, receipt returned) is driven through a
  # sandboxed CLI in hardening_test.rb.
  def test_write_file_refuses_an_absolute_path_outside_the_project
    target = File.join(@tmp, "deep/nested/y.txt")
    out = RubyClaw.call("write_file", { "path" => target, "content" => "hi" })
    assert_match(/refusing to write/, out)
    refute File.exist?(target)
  end

  def test_grep_finds_matches_under_a_directory
    File.write(File.join(@tmp, "a.rb"), "needle_here = 1\n")
    File.write(File.join(@tmp, "b.txt"), "nothing\n")
    out = RubyClaw.call("grep", { "pattern" => "needle_here", "path" => @tmp })
    assert_match(/a\.rb/, out)
    refute_match(/b\.txt/, out)
  end

  # A model searching for an option-looking string ("--version", "--pre=cat", a log line
  # that starts with a dash) got grep's own version banner or "unrecognized option" instead
  # of a search result. `--` ends the options.
  def test_grep_treats_a_dash_pattern_as_a_pattern
    File.write(File.join(@tmp, "flags.txt"), "run with --version and --pre=cat\n")
    out = RubyClaw.call("grep", { "pattern" => "--version", "path" => @tmp })
    refute_match(/GNU grep/, out, "grep's own banner is not a search result")
    assert_match(/flags\.txt/, out)

    out = RubyClaw.call("grep", { "pattern" => "--pre=cat", "path" => @tmp })
    refute_match(/unrecognized option/, out)
  end

  # The timeout is clamped at both ends: a model asking for 60000 "seconds" held the call
  # for 16 hours, and 0 was handed to the kernel as-is.
  def test_the_term_timeout_is_clamped_to_something_sane
    out = RubyClaw.call("term", { "command" => "sleep 2; echo done", "timeout" => 0 })
    assert_match(/done/, out, "0 means 'the default', not a one-second deadline")
    refute_match(/TIMEOUT/, out)

    out = RubyClaw.call("term", { "command" => "sleep 3", "timeout" => -5 })
    assert_match(/TIMEOUT/, out, "a negative deadline clamps to one second")
    RubyClaw::Term.reset!
  end

  # The http builtin against a real (local) server, no internet involved.
  def test_http_returns_status_and_body
    llm = FakeLLM.new(models: %w[solo-model])
    out = RubyClaw.call("http", { "url" => "#{llm.base_url}/models" })
    assert_match(/200/, out)
    assert_match(/solo-model/, out)
  ensure
    llm&.stop
  end

  # A model that forgets an argument must get an error string, never a crash -- and the
  # argument it forgot must be named in it. (The old regex matched "nil", so it passed
  # for almost any output at all.)
  def test_every_builtin_answers_a_missing_argument_with_a_named_error
    { "read_file" => /path/, "write_file" => /path/, "grep" => /pattern/, "http" => /url/i }.each do |name, expected|
      out = RubyClaw.call(name, {})
      assert_kind_of String, out
      assert_match(/ERROR/, out)
      assert_match(expected, out, "#{name} should say which argument is missing")
    end
  end
end
