# frozen_string_literal: true
require_relative "test_helper"

# The tool surface is the thing the prompt cache is built around, so its shape is
# worth asserting precisely.
class RegistryTest < Minitest::Test
  include ClawTest

  # The surface the model starts with. It changed once, deliberately, when the harness
  # gained capabilities it cannot write for itself: a shell that stays open between
  # calls (term), a live browser (browser) and a durable job store (schedule).
  BUILTINS = %w[sh read_file write_file grep http remember term browser schedule extend].freeze

  def setup
    @tools = RubyClaw.tools.dup
    @order = RubyClaw.order.dup
  end

  def teardown
    RubyClaw.instance_variable_set(:@tools, @tools)
    RubyClaw.instance_variable_set(:@order, @order)
  end

  def register(name, params, origin: "test", &blk)
    RubyClaw.tool(name, description: "test tool", params: params, origin: origin,
                  replace: true, &(blk || proc { |_a| "ok" }))
  end

  def test_the_builtins_lead_the_order_and_are_exactly_these
    assert_equal BUILTINS, RubyClaw.order.first(BUILTINS.size),
                 "the builtin surface changed: that is a deliberate act, not an accident"
    BUILTINS.each { |n| assert_equal "builtin", RubyClaw.tools[n].origin }
  end

  def test_self_written_tools_are_appended_after_the_builtins
    rest = RubyClaw.order[BUILTINS.size..]
    refute_empty rest, "expected the tree to carry self-written tools"
    rest.each { |n| refute_equal "builtin", RubyClaw.tools[n].origin }
  end

  def test_every_schema_is_provider_shaped
    assert_equal RubyClaw.order.size, RubyClaw.schemas.size
    RubyClaw.schemas.each do |s|
      f = s[:function]
      assert_equal "function", s[:type]
      assert_match(/\A[a-z0-9_]+\z/, f[:name])
      refute_empty f[:description].to_s, "#{f[:name]} needs a description"
      assert_equal "object", f[:parameters][:type]
      assert_kind_of Hash, f[:parameters][:properties]
      assert_kind_of Array, f[:parameters][:required]
      f[:parameters][:required].each do |r|
        assert_kind_of String, r
        assert f[:parameters][:properties].key?(r), "#{r} required but not declared"
      end
      f[:parameters][:properties].each do |pname, spec|
        assert_kind_of Hash, spec, "#{f[:name]}.#{pname} must be a schema object"
        assert_kind_of String, spec["type"], "#{f[:name]}.#{pname} needs a string type"
      end
    end
  end

  def test_schemas_serialise_to_json
    round = JSON.parse(JSON.generate(RubyClaw.schemas))
    assert_equal RubyClaw.schemas.size, round.size
    assert_equal "object", round.last["function"]["parameters"]["type"]
  end

  # The bug that reached a live session: a model writing required on the parameter,
  # the OpenAPI way. Intent is right, placement is wrong.
  def test_per_parameter_required_is_lifted_to_the_object
    register("t_lift", { "alpha" => { type: "string", required: true },
                         "beta" => { type: "string", required: false } })
    t = RubyClaw.tools["t_lift"]
    assert_equal %w[alpha], t.required
    refute t.params["alpha"].key?("required"), "the key must not reach the provider"
    refute t.params["beta"].key?("required")
    assert_equal ["alpha"], RubyClaw.schemas.last[:function][:parameters][:required]
  end

  def test_a_param_without_a_type_is_not_silently_repaired
    register("t_shape", { "thing" => { description: "no type" } })
    assert_nil RubyClaw.tools["t_shape"].params["thing"]["type"]
  end

  def test_deep_stringify_accepts_symbol_keys
    register("t_sym", { thing: { type: "string" } })
    assert_equal({ "thing" => { "type" => "string" } }, RubyClaw.tools["t_sym"].params)
  end

  def test_duplicate_registration_is_refused
    register("t_dup", {})
    assert_raises(RubyClaw::Error) do
      RubyClaw.tool("t_dup", description: "again", params: {}) { |_a| "x" }
    end
  end

  def test_call_passes_string_keyed_args
    register("t_args", { "n" => { type: "string" } }) { |a| "got #{a['n'].inspect}" }
    assert_equal 'got "hi"', RubyClaw.call("t_args", { n: "hi" })
  end

  def test_call_supports_keyword_blocks
    register("t_kw", { "command" => { type: "string" } }) { |command:| "ran #{command}" }
    assert_equal "ran ls", RubyClaw.call("t_kw", { "command" => "ls" })
  end

  def test_call_unknown_tool_explains_instead_of_raising
    out = RubyClaw.call("nope_not_here", {})
    assert_match(/no such tool/, out)
    assert_match(/sh/, out)
  end

  def test_call_returns_errors_as_text_a_model_can_act_on
    register("t_boom", {}) { |_a| raise "boom" }
    out = RubyClaw.call("t_boom", {})
    assert_match(/ERROR \(RuntimeError\): boom/, out)
  end

  def test_call_truncates_huge_output
    register("t_big", {}) { |_a| "x" * (RubyClaw::MAX_OUT + 5_000) }
    out = RubyClaw.call("t_big", {})
    assert_match(/\[truncated 5000 bytes\]/, out)
    assert_operator out.bytesize, :<, RubyClaw::MAX_OUT + 200
  end

  def test_redaction_hides_secret_shaped_args
    red = RubyClaw.redact({ "api_key" => "sk-real", "url" => "https://x",
                            "nested" => { "authorization" => "Bearer secret" } })
    assert_equal "[redacted]", red["api_key"]
    assert_equal "[redacted]", red["nested"]["authorization"]
    assert_equal "https://x", red["url"]
  end

  def test_redaction_truncates_giant_arguments
    red = RubyClaw.redact("y" * 600)
    assert_match(/\[600\]/, red)
  end

  # A tool that calls exit -- a self-written one with a stray `exit` on a failure path, or
  # anything shelling out badly -- used to take the whole harness down mid-conversation:
  # measured, `exit 9` inside a tool ended the process with status 9 and told the model
  # nothing. The registry is the boundary where that stops.
  def test_a_tool_that_exits_the_process_is_contained
    register("t_exit", {}) { |_a| exit 9 }
    out = RubyClaw.call("t_exit", {})
    assert_match(/SystemExit/, out)
    assert_match(/must return, not exit/, out)
  end

  def test_a_tool_that_aborts_is_contained_too
    register("t_abort", {}) { |_a| abort("nope") }
    assert_match(/SystemExit/, RubyClaw.call("t_abort", {}))
  end
end
