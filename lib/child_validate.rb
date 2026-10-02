# frozen_string_literal: true
# Runs in a throwaway child process (see SelfWrite.child_validate).
#
# Loads the staged file into a fresh registry, exercises everything it registered,
# and writes a JSON verdict to ENV["CLAW_VERDICT"], tagged with the nonce in
# ENV["CLAW_VERDICT_NONCE"] so the parent knows the verdict is this script's.
#
# It used to print the verdict as its last stdout line, which meant a proposal could
# print a verdict of its own and exit!(0) -- that is how a tool that always raises
# got promoted. The parent now also needs the exit status and a verdict file.
#
# Whatever the proposal does -- raise, exit, loop, print -- dies with this process,
# which is handed a stripped environment on purpose: no credentials, and
# CLAW_NO_DOTENV so it cannot read .env either.
require_relative "boot"

staged, test_json, replace_name = ARGV
verdict = { "ok" => false }

def provider_shaped?(t)
  t.description.is_a?(String) && !t.description.empty? && t.params.is_a?(Hash) &&
    t.params.values.all? { |v| v.is_a?(Hash) && v["type"].is_a?(String) } &&
    t.required.is_a?(Array) && t.required.all? { |r| r.is_a?(String) && t.params.key?(r) } &&
    JSON.generate(t.params).is_a?(String)
end

# Every tool the file registered is exercised, not just the first: a proposal could
# register one working tool and one broken tool, and only the first was ever called.
# Returns [failure_message_or_nil, detail_lines].
def exercise(added, test_json)
  args = JSON.parse(test_json)
  raise RubyClaw::Error, "test args must be a JSON object" unless args.is_a?(Hash)

  lines = []
  added.each do |n|
    out = RubyClaw.invoke(RubyClaw.tools[n], args)
    out = out.is_a?(String) ? out : JSON.generate(out)
    return ["tool `#{n}` raised on its own test args: #{out[0, 300]}", []] if out.start_with?("ERROR (")

    lines << "#{n}(#{JSON.generate(args)}) -> #{out[0, 200].inspect}"
  end
  [nil, lines]
end

begin
  RubyClaw.tools.delete(replace_name) if replace_name && !replace_name.empty?
  before = RubyClaw.tools.keys

  RubyClaw.current_origin = File.basename(staged)
  load staged

  added = RubyClaw.tools.keys - before
  if added.empty?
    verdict["error"] = "file loaded but registered no tool (need a RubyClaw.tool(...) call at load time)"
  elsif (bad = added.reject { |n| provider_shaped?(RubyClaw.tools[n]) }).any?
    verdict["error"] = "registered tool(s) whose JSON schema is not provider-shaped " \
                       "(each param needs a string \"type\"; \"required\" belongs on the " \
                       "object, not on the parameter): #{bad.join(', ')}"
  else
    detail = "registered #{added.join(', ')}"
    if test_json.to_s.strip.empty?
      detail += " (no test args supplied — loaded, not exercised)"
    else
      failure, lines = exercise(added, test_json)
      if failure
        verdict["error"] = failure
      else
        detail += "; test args #{lines.join('; ')}"
      end
    end
    unless verdict["error"]
      verdict["ok"] = true
      verdict["added"] = added
      verdict["detail"] = detail
    end
  end
rescue StandardError, ScriptError => e
  # ScriptError as well as StandardError, and deliberately not Exception: a proposal
  # containing a syntax error raises SyntaxError, which is *not* a StandardError and
  # would otherwise leave no verdict at all -- while Interrupt and SystemExit should
  # still take the child down.
  verdict["error"] = "#{e.class}: #{e.message}"
  verdict["backtrace"] = Array(e.backtrace).first(6).join("\n")
end

verdict["nonce"] = ENV["CLAW_VERDICT_NONCE"].to_s
json = JSON.generate(verdict)
path = ENV["CLAW_VERDICT"].to_s
if path.empty?
  puts json
else
  File.write(path, json)
  File.chmod(0o600, path)
end
