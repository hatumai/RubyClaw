# frozen_string_literal: true
# A/B regression check for a proposed merge, run in a throwaway child process.
#
# Usage: ruby lib/child_ab.rb <staged_path> <merged_name> <rows_json>
#   rows_json = [{"tool":"original","args":{...}}, ...]   <- recorded from real use
#
# For each row: call the ORIGINAL tool with the arguments it was really called with and
# snapshot the output, then load the staged merged tool and replay the same calls.
#
# It deliberately does NOT score its replay, and returns only raw text. The merged tool
# is loaded in this process, so it can redefine anything here -- including
# RubyClaw.similarity, which is exactly how a merge that returned garbage once scored
# 1.0 and was committed. Scoring happens in the parent, on this output.
#
# Nothing here touches the live registry: the merged tool is only ever loaded here, so a
# merge that fails its replay never goes live.
require_relative "boot"

# Enough text for the parent to score on; it truncates further to show a diff.
SNAPSHOT_CHARS = 4000

def snapshot(rows)
  rows.map do |r|
    out = begin
      # internal: true -- this replays calls that already happened, for comparison; the
      # autonomy policy belongs to the model's actions, not to the harness's own audit.
      RubyClaw.call(r["tool"], r["args"], internal: true)
    rescue StandardError => e
      "ERROR: #{e.class}: #{e.message}"
    end
    { "tool" => r["tool"], "args" => r["args"], "out" => out.to_s[0, SNAPSHOT_CHARS] }
  end
end

def replay(before, merged_name)
  before.map do |b|
    out = begin
      RubyClaw.call(merged_name, b["args"], internal: true)
    rescue StandardError => e
      "ERROR: #{e.class}: #{e.message}"
    end
    { "tool" => b["tool"], "args" => b["args"],
      "before" => b["out"], "after" => out.to_s[0, SNAPSHOT_CHARS] }
  end
end

def run_ab(staged, merged_name, rows_json)
  rows = begin
    JSON.parse(rows_json.to_s)
  rescue JSON::ParserError
    []
  end
  rows = [] unless rows.is_a?(Array)
  before = snapshot(rows)

  # Replace semantics: the merged tool may take one of the originals' names.
  RubyClaw.tools.delete(merged_name)
  RubyClaw.order.delete(merged_name)
  RubyClaw.current_origin = File.basename(staged.to_s)
  load staged

  { "ok" => true, "merged" => merged_name, "rows" => replay(before, merged_name),
    "registered" => RubyClaw.tools.key?(merged_name) }
rescue StandardError, ScriptError => e
  # ScriptError too: a staged merge with a syntax error must still produce a verdict.
  { "ok" => false, "error" => "#{e.class}: #{e.message}",
    "backtrace" => Array(e.backtrace).first(6).join("\n") }
end

puts JSON.generate(run_ab(*ARGV)) if $PROGRAM_NAME == __FILE__
