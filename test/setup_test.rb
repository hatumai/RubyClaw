# frozen_string_literal: true
require_relative "test_helper"

# The first-run wizard, driven end to end in a sandbox: a fake endpoint, a fake Bot
# API, piped answers. What matters is that it writes the right files, in the right
# places, and writes nothing at all when something does not answer.
class SetupTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("setup")
    @sb.git_init!
  end

  def teardown
    @sb.cleanup
    @llm&.stop
    @tg&.stop
  end

  def test_the_full_wizard_configures_a_bare_tree
    @llm = FakeLLM.new(script: [FakeLLM.says("ready")], models: %w[model-one model-two])
    @tg = FakeTG.new(updates: [FakeTG.message(4242, "hello")])
    answers = ["7", @llm.base_url, "sk-test-key", "", "y", "stub-token", "y", "3"].join("\n") + "\n"
    out, st = @sb.claw("setup", "--interactive", stdin: answers,
                       env: { "CLAW_TELEGRAM_API_BASE" => @tg.base })
    assert st.success?, out
    assert_match(/ok — model-one said "ready"/, out)
    assert_match(/connected as @stub_bot/, out)
    assert_match(/message from the operator — chat id 4242/, out)

    cfg = YAML.safe_load(@sb.read("config.yml"))
    assert_equal "model-one", cfg["model"]
    assert_equal @llm.base_url, cfg["base_url"]
    assert_equal [4242], cfg["telegram_allowed_chat_ids"]
    assert_equal true, cfg["setup_complete"]

    env = @sb.read(".env")
    assert_match(/^CLAW_API_KEY=sk-test-key$/, env)
    assert_match(/^CLAW_TELEGRAM_TOKEN=stub-token$/, env)
    refute_match(/sk-test-key|stub-token/, @sb.read("config.yml"), "no secret in the tracked file")
    assert_equal 0o600, File.stat(@sb.path(".env")).mode & 0o777
    assert @sb.exist?("preferences.md"), "the markdown it learns in must exist from the start"
    assert_equal 1, @llm.call_count, "exactly one verification request"
  end

  def test_an_endpoint_that_does_not_answer_writes_nothing
    @llm = FakeLLM.new(status: 401, body: '{"error":"bad key"}')
    # A fresh tree has no config.yml at all now, so "unchanged" has to mean
    # "still absent" rather than "equal to what was read a moment ago".
    before = @sb.exist?("config.yml") ? @sb.read("config.yml") : nil
    out, st = @sb.claw("setup", "--interactive",
                       stdin: ["7", @llm.base_url, "sk-bad", "model-x"].join("\n") + "\n")
    assert st.success?, out
    assert_match(/No answer from that endpoint, so nothing has been written/, out)
    if before.nil?
      # Nothing was there before, so "unchanged" means it must not have appeared.
      refute @sb.exist?("config.yml"),
             "a setup that could not verify must not create config.yml"
    else
      assert_equal before, @sb.read("config.yml"),
                   "a setup that could not verify must leave config.yml alone"
    end
    refute @sb.exist?(".env")
  end

  def test_a_bad_telegram_token_is_caught_before_anything_is_saved
    @llm = FakeLLM.new(script: [FakeLLM.says("ready")])
    @tg = FakeTG.new(errors: { "getMe" => "Unauthorized" })
    out, st = @sb.claw("setup", "--interactive",
                       stdin: ["7", @llm.base_url, "sk-key", "", "y", "wrong-token"].join("\n") + "\n",
                       env: { "CLAW_TELEGRAM_API_BASE" => @tg.base })
    refute st.success?
    assert_match(/that token did not work/, out)
    assert_match(/Unauthorized/, out)
    refute @sb.exist?(".env")
  end

  def test_setup_can_run_non_interactively_from_the_environment
    @llm = FakeLLM.new(script: [FakeLLM.says("ready")])
    out, st = @sb.claw("setup", "--non-interactive",
                       env: { "CLAW_MODEL" => "model-one", "CLAW_BASE_URL" => @llm.base_url,
                              "CLAW_API_KEY" => "sk-env" })
    assert st.success?, out
    cfg = YAML.safe_load(@sb.read("config.yml"))
    assert_equal "model-one", cfg["model"]
    assert_equal true, cfg["setup_complete"]
    assert_match(/CLAW_API_KEY=sk-env/, @sb.read(".env"),
                 "a headless setup must persist the credential it was given")
  end

  def test_running_the_cli_unconfigured_under_a_pipe_says_what_to_do
    out, st = @sb.claw()
    refute st.success?
    assert_match(/no model configured/, out)
    assert_match(/claw setup/, out)
    refute_match(/\tfrom /, out, "a sentence, not a backtrace")
  end

  def test_running_the_cli_configured_under_a_pipe_just_chats
    @sb.write(".env", "CLAW_API_KEY=sk-x\n")
    @sb.write("config.yml", "model: m\nbase_url: https://x/v1\nsetup_complete: true\n")
    out, st = @sb.claw(env: { "CLAW_BASE_URL" => "http://127.0.0.1:1/v1" })
    assert st.success?, out
    assert_match(/RubyClaw —/, out)
    assert_match(/bye\./, out)
  end
end
