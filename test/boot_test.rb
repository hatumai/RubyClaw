# frozen_string_literal: true
require_relative "test_helper"

# Resolution order and the output-comparison rules the merge gate depends on.
class BootTest < Minitest::Test
  include ClawTest

  def test_env_overrides_config_for_model_and_endpoint
    with_env("CLAW_MODEL" => "from-env", "CLAW_BASE_URL" => "https://env.example/v1/") do
      assert_equal "from-env", RubyClaw.model_name
      assert_equal "https://env.example/v1", RubyClaw.base_url, "trailing slash is normalised"
    end
  end

  # An exported-but-empty variable is not a value. Getting this wrong broke a headless
  # `claw setup` once: it wrote config.yml, lost the key, and CLAW_MODEL= would have
  # shadowed the configured model.
  def test_an_empty_environment_variable_does_not_shadow_the_config_file
    with_env("CLAW_MODEL" => "", "CLAW_BASE_URL" => "") do
      expected = RubyClaw.config["model"].to_s.empty? ? "deepseek-chat" : RubyClaw.config["model"]
      assert_equal expected, RubyClaw.model_name
      refute_equal "", RubyClaw.base_url
      refute_nil RubyClaw.base_url
    end
  end

  def test_config_is_the_fallback
    with_env("CLAW_MODEL" => nil) do
      # config.yml is instance state and is no longer in the repository, so "the
      # configured model" may legitimately be nothing at all -- in which case
      # model_name must return the built-in default. Comparing against
      # config["model"] alone only passed while a config.yml happened to be tracked.
      expected = RubyClaw.config["model"] || "deepseek-chat"
      assert_equal expected, RubyClaw.model_name
    end
  end

  def test_model_name_default_is_deepseek_chat
    assert_equal "deepseek-chat", RubyClaw.model_name if RubyClaw.config["model"].nil?
  end

  def test_key_source_names_the_source_never_the_value
    with_env("CLAW_API_KEY" => "sk-very-secret") do
      assert_equal "$CLAW_API_KEY", RubyClaw.key_source
      refute_match(/very-secret/, RubyClaw.key_source)
    end
    with_env("CLAW_API_KEY" => nil) do
      # With nothing configured it borrows the credential Hermes already stores
      # rather than duplicating a secret; the name is reported, never the value.
      assert_includes %w[none ~/.hermes/.env], RubyClaw.key_source if RubyClaw.config["api_key"].nil?
    end
  end

  def test_override_sets_credentials_for_this_process_only
    with_env("CLAW_API_KEY" => nil, "CLAW_MODEL" => nil) do
      RubyClaw.override!(api_key: "sk-trial", model: "trial-model")
      assert_equal "sk-trial", RubyClaw.api_key
      assert_equal "trial-model", RubyClaw.model_name
    end
    refute_equal "trial-model", RubyClaw.model_name
  end

  # The merge gate's whole rule: a digest-only answer must match exactly, because a
  # lenient comparison would rubber-stamp the one merge that changes what callers get.
  def test_similarity_is_exact_when_there_is_nothing_to_compare
    assert_equal 1.0, RubyClaw.similarity("2cf24dba5fb0a30e", "2cf24dba5fb0a30e")
    assert_equal 0.0, RubyClaw.similarity("2CF24DBA5FB0A30E", "2cf24dba5fb0a30e")
  end

  def test_similarity_ignores_volatile_but_not_content
    before = "title: hello world id 1234567890 at 2026-09-30"
    assert_equal 1.0, RubyClaw.similarity(before, "title: hello world id 9999999999 at 2026-10-01")
    assert_operator RubyClaw.similarity(before, "title: goodbye world"), :<, 1.0
  end

  def test_content_tokens_drop_numbers_and_digests
    toks = RubyClaw.content_tokens("abc 123 2cf24dba5fb0a30e11 zz")
    assert_includes toks, "abc"
    refute_includes toks, "123"
    refute_includes toks, "2cf24dba5fb0a30e11"
  end

  def test_norm_text_collapses_whitespace_but_keeps_case
    assert_equal "a b C", RubyClaw.norm_text("  a\n b\tC  ")
  end
end
