# frozen_string_literal: true
require_relative "test_helper"

# Configuration resolution, in a tree with no .env and a config.yml of the test's
# choosing -- the state a freshly installed copy is in.
class ConfigTest < Minitest::Test
  include ClawTest

  def setup
    @sb = ClawTest::Sandbox.new("config")
  end

  def teardown
    @sb.cleanup
  end

  def value(code, env = {})
    out, st = @sb.ruby('require "boot"; puts((' + code + '))', env: env)
    assert st.success?, out
    out.strip
  end

  def test_config_file_is_used_when_the_environment_says_nothing
    @sb.write("config.yml", "model: from-file\nbase_url: https://file.example/v1\n")
    assert_equal "from-file", value("RubyClaw.model_name")
    assert_equal "https://file.example/v1", value("RubyClaw.base_url")
  end

  def test_environment_beats_the_config_file
    @sb.write("config.yml", "model: from-file\nbase_url: https://file.example/v1\n")
    assert_equal "from-env", value("RubyClaw.model_name", "CLAW_MODEL" => "from-env")
  end

  def test_env_file_is_read_but_yields_to_the_real_environment
    @sb.write("config.yml", "model: m\nbase_url: https://x/v1\n")
    @sb.write(".env", "CLAW_API_KEY=from-dotenv\n")
    assert_equal "from-dotenv", value("RubyClaw.api_key")
    assert_equal "from-shell", value("RubyClaw.api_key", "CLAW_API_KEY" => "from-shell")
  end

  def test_missing_config_file_is_not_fatal
    FileUtils.rm_f(@sb.path("config.yml"))
    assert_equal "deepseek-chat", value("RubyClaw.model_name")
    assert_equal "https://api.deepseek.com/v1", value("RubyClaw.base_url")
  end

  def test_a_key_in_config_dot_yml_wins_but_is_reported_as_such
    @sb.write("config.yml", "model: m\nbase_url: https://x/v1\napi_key: sk-in-file\n")
    assert_equal "config.yml", value("RubyClaw.key_source")
  end

  def test_reload_picks_up_a_rewritten_config_without_restarting
    @sb.write("config.yml", "model: first\nbase_url: https://x/v1\n")
    out, st = @sb.ruby(<<~RB)
      require "boot"
      before = RubyClaw.model_name
      File.write(File.join(RubyClaw::ROOT, "config.yml"), "model: second\nbase_url: https://x/v1\n")
      RubyClaw.reload_config!
      puts [before, RubyClaw.model_name].join(" -> ")
    RB
    assert st.success?, out
    assert_equal "first -> second", out.strip
  end

  def test_a_fresh_copy_needs_setup_and_a_configured_one_does_not
    assert_equal "true", value('require "setup"; RubyClaw::Setup.needed?')
    @sb.write("config.yml", "model: m\nbase_url: https://x/v1\nsetup_complete: true\n")
    assert_equal "false", value('require "setup"; RubyClaw::Setup.needed?')
  end

  def test_a_local_endpoint_needs_no_key
    @sb.write("config.yml", "model: m\nbase_url: http://127.0.0.1:11434/v1\n")
    assert_equal "false", value('require "setup"; RubyClaw::Setup.needed?')
  end
end
