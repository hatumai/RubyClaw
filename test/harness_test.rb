# frozen_string_literal: true
require_relative "test_helper"

# The agent loop, run for real in a sandbox against a scripted endpoint: one tool
# call then an answer, the prompt the endpoint actually received, and the rule that a
# preference recorded mid-conversation applies to the very next request.
class HarnessTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("harness")
    @sb.git_init!
  end

  def teardown
    @sb.cleanup
    @llm&.stop
  end

  def run_task(task, model: "fake", quiet: true, max_steps: nil)
    @llm ||= FakeLLM.new
    env = { "CLAW_BASE_URL" => @llm.base_url, "CLAW_MODEL" => model, "CLAW_API_KEY" => "x",
            "CLAW_NO_USAGE" => "1" }
    code = <<~RB
      require "boot"; require "harness"
      h = RubyClaw::Harness.new(quiet: #{quiet}#{max_steps ? ", max_steps: #{max_steps}" : ""})
      answer = h.run(#{task.dump})
      puts JSON.generate({ "answer" => answer, "usage" => h.usage,
                           "transcripts" => Dir[File.join(RubyClaw::LOG_DIR, "session-*.jsonl")].size })
    RB
    out, st = @sb.ruby(code, env: env)
    assert st.success?, out
    JSON.parse(out.lines.last)
  end

  def test_one_tool_call_then_an_answer
    @llm = FakeLLM.new(script: [FakeLLM.calls("sh", command: "echo hi"),
                                FakeLLM.says("the shell said hi")])
    h = run_task("echo something")
    assert_equal "the shell said hi", h["answer"]
    assert_equal 2, @llm.call_count
    assert_equal 1, h["transcripts"], "a transcript should be written"
    # the tool result really came back from the shell
    tool_msg = @llm.last_body["messages"].find { |m| m["role"] == "tool" }
    assert_match(/hi/, tool_msg["content"])
    assert_equal "sh", tool_msg["name"]
  end

  def test_the_endpoint_receives_the_tool_surface_and_the_rules
    @llm = FakeLLM.new(script: [FakeLLM.says("ok")])
    run_task("say ok")
    body = @llm.last_body
    names = body["tools"].map { |t| t["function"]["name"] }
    assert_equal RubyClaw.order, names, "schemas must go out in registry order, builtins first"
    assert_equal "auto", body["tool_choice"]
    system = body["messages"].first["content"]
    assert_match(/self-building agent harness/, system)
    assert_match(/extend/, system)
  end

  def test_usage_is_accounted_for
    @llm = FakeLLM.new(script: [FakeLLM.says("hi", usage: { "prompt_tokens" => 100,
                                                            "completion_tokens" => 7,
                                                            "prompt_cache_hit_tokens" => 40 })])
    h = run_task("hi")
    assert_equal 100, h["usage"]["prompt"]
    assert_equal 40, h["usage"]["cached"]
    assert_equal 7, h["usage"]["completion"]
    assert_equal 1, h["usage"]["calls"]
  end

  def test_an_existing_preference_is_in_the_first_prompt
    @sb.write("preferences.md", "# Preferences\n- 2026-01-01 answer in one line\n")
    @llm = FakeLLM.new(script: [FakeLLM.says("ok")])
    run_task("hi")
    system = @llm.requests.first[:body]["messages"].first["content"]
    assert_match(/answer in one line/, system)
    assert_match(/Preferences the user has stated/, system)
  end

  # The learning-as-it-goes rule: recorded mid-conversation, in force immediately.
  def test_a_preference_recorded_mid_session_applies_to_the_next_request
    @llm = FakeLLM.new(script: [FakeLLM.calls("remember", note: "never use emoji", kind: "preference"),
                                FakeLLM.says("understood")])
    h = run_task("note that I hate emoji")
    assert_equal "understood", h["answer"]
    assert_equal 2, @llm.call_count
    first = @llm.requests[0][:body]["messages"].first["content"]
    second = @llm.requests[1][:body]["messages"].first["content"]
    refute_match(/never use emoji/, first, "not known before it was written")
    assert_match(/never use emoji/, second, "must be in force on the next request")
    assert_match(/never use emoji/, @sb.read("preferences.md"))
  end

  def test_the_loop_is_bounded
    @llm = FakeLLM.new(script: [FakeLLM.calls("sh", command: "echo again")])   # repeats
    h = run_task("loop forever", max_steps: 3)
    assert_match(/hit the 3-step ceiling/, h["answer"].to_s, "it stops and says so")
    assert_equal 3, @llm.call_count
  end

  def test_a_provider_error_is_a_sentence_not_a_crash
    @llm = FakeLLM.new(status: 401, body: '{"error":{"message":"bad key"}}')
    env = { "CLAW_BASE_URL" => @llm.base_url, "CLAW_API_KEY" => "nope",
            "CLAW_MODEL" => "fake", "CLAW_NO_USAGE" => "1" }
    out, st = @sb.ruby(<<~'RB', env: env)
      require "boot"; require "harness"
      begin
        RubyClaw::Harness.new(quiet: true).run("hi")
      rescue RubyClaw::Error => e
        puts "SENTENCE: #{e.message}"
      end
    RB
    assert st.success?, out
    assert_match(/SENTENCE: provider returned 401/, out)
  end
end
