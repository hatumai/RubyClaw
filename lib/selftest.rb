# frozen_string_literal: true
# `claw selftest` — proves the growth machinery works without touching the tools
# that are actually in use, and proves it *refuses* bad code. Run after any core
# patch, before trusting the thing.
#
# A selftest makes real tool calls from the real tree (it proves `sh` and `http` reach
# the world), so it must not write the project's own durable store: it sets CLAW_SELFTEST,
# and Policy.audit honours it the way SelfWrite and Update do. After a selftest the work
# store is untouched -- no data/work.json, data/approvals.json or data/events.jsonl.
require_relative "boot"

module RubyClaw
  module Selftest
    GOOD = <<~'RB'
      RubyClaw.tool "selftest_echo",
        description: "Echo a value back, uppercased. Exists only to prove the self-write pipeline.",
        params: { "value" => { type: "string" } } do |a|
        a["value"].to_s.upcase
      end
    RB

    RAISES = <<~'RB'
      RubyClaw.tool "selftest_broken",
        description: "Loads fine, explodes when called.",
        params: { "x" => { type: "string" } } do |a|
        raise "boom: #{a['x']}"
      end
    RB

    SILENT = "# nothing here registers a tool\nX = 1\n"

    # The mistake that broke a live session: `required` written on the parameter
    # instead of the object. Intent is right, placement is wrong -- normalise it.
    PARAM_REQUIRED = <<~'RB'
      RubyClaw.tool "selftest_req",
        description: "Declares required the OpenAPI way, on the parameter.",
        params: { "name" => { type: "string", description: "who", required: true },
                  "loud" => { type: "boolean", required: false } } do |a|
        a["name"].to_s
      end
    RB

    BROKEN_SCHEMA = <<~'RB'
      RubyClaw.tool "selftest_shape",
        description: "Param declared without a type.",
        params: { "thing" => { description: "no type here" } } do |a|
        a["thing"].to_s
      end
    RB

    BAD_SYNTAX = "RubyClaw.tool 'oops' do\n"

    def self.run
      ENV["CLAW_SELFTEST"] = "1"   # keep fixture rejections out of log/evolution.jsonl
      results = []
      check = lambda do |label, ok, detail = nil|
        results << [label, ok, detail.to_s[0, 220]]
        puts "#{ok ? 'PASS' : 'FAIL'}  #{label}#{ok ? '' : "\n      #{detail.to_s[0, 220]}"}"
      end

      # surface
      check.call("tool surface is #{RubyClaw.tools.size} tools",
                 RubyClaw.tools.size >= 7, RubyClaw.tools.keys.join(", "))
      check.call("schemas are well-formed",
                 RubyClaw.schemas.all? { |s| s.dig(:function, :name) && s.dig(:function, :parameters, :type) == "object" },
                 JSON.generate(RubyClaw.schemas.first))
      dyn = RubyClaw.dynamic_tool_names
      check.call("dynamic tools appended after builtins",
                 RubyClaw.schemas.map { |s| s[:function][:name] }.last(dyn.size) == dyn,
                 "loaded: #{dyn.join(', ')}")

      # builtins actually reach the world
      check.call("sh builtin reaches the shell", RubyClaw.run_shell("echo hi").include?("hi"))
      z = RubyClaw.call("http", { "url" => "https://api.github.com/zen" })
      check.call("http builtin reaches the network", z.start_with?("200"), z[0, 80])

      # the pipeline: good code validates
      good = SelfWrite.propose(kind: "tool", name: "selftest_echo", source: GOOD,
                               test: '{"value":"hello"}', dry_run: true)
      check.call("good tool validates in a child process", good.start_with?("DRY RUN"), good)

      # ...and bad code is refused, not promoted
      bad = SelfWrite.propose(kind: "tool", name: "selftest_broken", source: RAISES,
                              test: '{"x":"y"}', dry_run: true)
      check.call("tool that raises on its own test args is refused", bad.start_with?("REJECTED"), bad)

      probe = SelfWrite.run_boot_probe
      check.call("the boot probe reports a healthy tree", probe[:ok] == true, probe.inspect[0, 120])

      req = SelfWrite.propose(kind: "tool", name: "selftest_req", source: PARAM_REQUIRED,
                              test: '{"name":"x","loud":false}', dry_run: true)
      check.call("per-parameter `required` is normalised, not rejected", req.start_with?("DRY RUN"), req)

      shape = SelfWrite.propose(kind: "tool", name: "selftest_shape", source: BROKEN_SCHEMA, dry_run: true)
      check.call("param without a type is refused as a bad schema", shape.start_with?("REJECTED"), shape)

      silent = SelfWrite.propose(kind: "tool", name: "selftest_silent", source: SILENT, dry_run: true)
      check.call("file that registers nothing is refused", silent.start_with?("REJECTED"), silent)

      syn = SelfWrite.propose(kind: "tool", name: "selftest_syntax", source: BAD_SYNTAX, dry_run: true)
      check.call("syntax error is refused", syn.start_with?("REJECTED"), syn)

      # The shell that stays open, and the job store: both are new enough that a
      # regression in either would be invisible until someone relied on it.
      begin
        t = Term.new
        t.run("cd /tmp && export CLAW_SELFTEST=1")
        out, = t.run("echo $CLAW_SELFTEST:$PWD")
        check.call("term keeps cwd and exports between calls", out.include?("1:/tmp"), out.strip)
      rescue StandardError => e
        check.call("term keeps cwd and exports between calls", false, "#{e.class}: #{e.message}")
      ensure
        t&.close
      end

      begin
        spec = Schedule.parse_spec("every 15m")
        nxt = Schedule.next_at(spec.merge("name" => "selftest"), from: Time.now)
        check.call("schedule reads a spec and dates the next run",
                   spec["seconds"] == 900 && nxt > Time.now, "#{spec.inspect} -> #{nxt}")
      rescue StandardError => e
        check.call("schedule reads a spec and dates the next run", false, "#{e.class}: #{e.message}")
      end

      leaked = [CORE_TOOLS_DIR, TOOLS_DIR].flat_map { |d| Dir[File.join(d, "selftest_*")] }
      check.call("no staging leaked into the tool directories", leaked.empty?, leaked.join(", "))

      ok = results.all? { |_, o, _| o }
      puts "\n#{results.count { |_, o, _| o }}/#{results.size} checks passed"
      ok
    end
  end
end