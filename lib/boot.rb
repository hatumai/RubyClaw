# frozen_string_literal: true
# RubyClaw — a self-building agent harness.
#
# Layout contract (everything the harness knows about itself):
#   lib/           the fixed core: loop, registry, self-write pipeline
#   tools/         Ruby that *ships* with the project, one file per tool
#   skills/        markdown procedures that ship with the project
#   instance/tools/   Ruby the harness wrote itself (grows forever, never shipped)
#   instance/skills/  markdown procedures the harness wrote (grows forever, never shipped)
#   memory.md      durable notes the harness wrote
#   log/           transcripts
#
# The shipped and the instance's own tool/skill sets are separate directories on
# purpose. An update may legitimately replace anything under tools/ and skills/ --
# they are the project's -- so growth kept there is only protected by comparing
# contents after the fact. instance/ is refused by path before any comparison, so
# keeping the harness's own growth there makes that protection structural.
#
# Nothing below `lib/` is ever edited in place while the process is running.
require "json"
require "yaml"
require "open3"
require "fileutils"
require "securerandom"
require "time"
require "timeout"
require "rbconfig"

module RubyClaw
  ROOT       = File.expand_path("..", __dir__)
  # The shipped sets: upstream also writes into these, so a local file here is only
  # protected by the content comparison in update.rb.
  CORE_TOOLS_DIR  = File.join(ROOT, "tools")
  CORE_SKILLS_DIR = File.join(ROOT, "skills")
  # The growth sets: everything the harness writes for itself. instance/ is in
  # update.rb's LOCAL_ONLY, so an update refuses these paths by path.
  TOOLS_DIR  = File.join(ROOT, "instance", "tools")
  SKILLS_DIR = File.join(ROOT, "instance", "skills")
  LOG_DIR    = File.join(ROOT, "log")
  STAGE_DIR  = File.join(ROOT, ".staging")
  MEMORY     = File.join(ROOT, "memory.md")
  MAX_OUT    = 8_000   # bytes of any single tool result handed back to the model

  class Error < StandardError; end

  # Tool output arrives as whatever the tool produced: a binary read, a shell command,
  # a file with mixed encodings. Force UTF-8 and scrub it, because JSON.generate
  # refuses invalid UTF-8 and that raise takes the turn -- and every turn after it,
  # since the poisoned message stays in the conversation.
  #
  # String#scrub alone is not enough: on an ASCII-8BIT string every byte is valid, so
  # scrub silently does nothing. The force_encoding is the load-bearing half.
  def self.utf8(s)
    s.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  def self.git(*args, allow_fail: false)
    out, err, st = Open3.capture3("git", "-C", ROOT, *args)
    return out if st.success? || allow_fail
    raise Error, "git #{args.join(' ')}: #{err.strip}"
  end

  # ---- configuration -------------------------------------------------------

  # CLAW_NO_DOTENV=1 pins the environment: the test suite and the self-write
  # validator both need a process that cannot pick up this machine's real
  # credentials just by asking for its config (the old `ENV[k] ||= v` re-read .env
  # lazily, so a test that deleted the key got it back on the first config call).
  def self.dotenv(force: false)
    return if ENV["CLAW_NO_DOTENV"].to_s == "1"

    env = File.join(ROOT, ".env")
    return unless File.exist?(env)
    File.readlines(env).each do |l|
      k, v = l.strip.split("=", 2)
      next unless k && v && !k.start_with?("#")
      force ? ENV[k] = v : (ENV[k] ||= v)
    end
  end

  # Try candidate credentials for this process only, before they are written
  # anywhere. Used by `claw setup`, which must not persist a key it has not yet
  # proven works.
  # Blank counts as "not given": passing "" here must not wipe a real key that the
  # caller already has in the environment (that bug lost the credential a headless
  # `claw setup` had just been handed).
  def self.override!(api_key: nil, base_url: nil, model: nil)
    ENV["CLAW_API_KEY"] = api_key unless api_key.to_s.empty?
    ENV["CLAW_BASE_URL"] = base_url unless base_url.to_s.empty?
    ENV["CLAW_MODEL"] = model unless model.to_s.empty?
    # Always drop the memo. Invalidating it only for a blank candidate meant a real
    # candidate was silently ignored: `claw model` kept reporting the key loaded at
    # startup, and the wizard verified that stale key instead of the one just typed.
    @api_key = nil
    @model = nil
    nil
  end

  # After config.yml or .env has been rewritten on disk.
  def self.reload_config!
    @config = nil
    @api_key = nil
    dotenv(force: true)
    config
    self
  end

  def self.config
    @config ||= begin
      dotenv
      path = File.join(ROOT, "config.yml")
      File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}
    end
  end

  # Resolution order: CLI flag > environment > config.yml > built-in default.
  # An exported-but-empty variable is not a value: `CLAW_MODEL=` must not shadow the
  # configured model.
  def self.from_env(key) = ENV[key].to_s.empty? ? nil : ENV[key]

  def self.model_name = from_env("CLAW_MODEL") || config["model"] || "deepseek-chat"

  def self.base_url
    (from_env("CLAW_BASE_URL") || config["base_url"] || "https://api.deepseek.com/v1").sub(%r{/+\z}, "")
  end

  # Where the key came from, for display. Never the key itself.
  def self.key_source
    return "config.yml" unless config["api_key"].to_s.empty?
    return "$CLAW_API_KEY" unless ENV["CLAW_API_KEY"].to_s.empty?
    return "$DEEPSEEK_API_KEY" unless ENV["DEEPSEEK_API_KEY"].to_s.empty?
    return "~/.hermes/.env" unless api_key.to_s.empty?
    "none"
  end

  def self.api_key
    @api_key ||= begin
      k = [config["api_key"], from_env("CLAW_API_KEY"), from_env("DEEPSEEK_API_KEY")].find { |v| !v.to_s.empty? }
      # CLAW_NO_DOTENV means "do not look for credentials on disk". The test helper sets it
      # so a test process never holds the machine's real key -- without this, an assertion
      # that failed while comparing keys printed the real one into the failure message.
      if k.to_s.empty? && ENV["CLAW_NO_DOTENV"].to_s.empty?
        hermes = File.join(ENV["HERMES_HOME"] || File.expand_path("~/.hermes"), ".env")
        if File.exist?(hermes)
          line = File.readlines(hermes).find { |l| l.start_with?("DEEPSEEK_API_KEY=") }
          k = line.split("=", 2).last.strip if line
        end
      end
      k
    end
  end

  # ---- output comparison ----------------------------------------------------
  # Used by the A/B replay that gates a merge: how much of the original tool's
  # answer survived into the merged tool's answer, for the arguments the original
  # was really called with.

  # Content words only: ids, timestamps and long hex digests are volatile by
  # nature (a clock moves, a hash covers bytes that changed), so comparing them
  # literally would fail every honest merge. Drop digits and long hex runs.
  def self.content_tokens(s)
    s.to_s.downcase.split(/[^a-z0-9_]+/).reject do |t|
      t.length < 3 || t.match?(/\A\d+\z/) || t.match?(/\A[0-9a-f]{16,}\z/)
    end.sort.uniq
  end

  # Whitespace-normalised but case-SENSITIVE: "2CF24D…" and "2cf24d…" are different
  # answers to a caller, so a case change is never waved through as equivalent.
  def self.norm_text(s) = s.to_s.gsub(/\s+/, " ").strip

  def self.similarity(before, after)
    tb = content_tokens(before)
    # Nothing comparable in the original (a bare digest, a single number): fall
    # back to strict equality. This is the case a lenient check would rubber-stamp
    # exactly the merge that silently changes what callers get.
    return (norm_text(before) == norm_text(after) ? 1.0 : 0.0) if tb.empty?
    ((tb & content_tokens(after)).size.to_f / tb.size).round(3)
  end
end

require_relative "proc"
require_relative "notes"
require_relative "registry"
require_relative "builtins"
require_relative "selfwrite"

module RubyClaw
  # The names of the dynamic (non-builtin) tools, in the order they are registered:
  # the shipped set first, then this instance's own. An instance tool of the same name
  # wins and keeps the shipped name's position, so uniq-by-first-occurrence is exactly
  # the load order -- and exactly the tail of RubyClaw.tools.keys.
  def self.dynamic_tool_names
    names = Dir[File.join(CORE_TOOLS_DIR, "*.rb")].sort.map { |f| File.basename(f, ".rb") }
    Dir[File.join(TOOLS_DIR, "*.rb")].sort.each { |f| names << File.basename(f, ".rb") }
    names.uniq
  end
end

# Dynamic tools load last, in filename order: the shipped set first, then this
# instance's own growth, so an instance tool of the same name overrides a shipped one
# instead of being refused as a duplicate. Either way the builtin tool list stays a
# stable prefix (and the prompt cache with it) while new tools append to the end.
[[RubyClaw::CORE_TOOLS_DIR, false], [RubyClaw::TOOLS_DIR, true]].each do |dir, growth|
  Dir[File.join(dir, "*.rb")].sort.each do |f|
    begin
      RubyClaw.current_origin = File.basename(f)
      # Free the name, leaving its position in the order, so an instance file can
      # override a shipped tool of the same name rather than crashing on load.
      RubyClaw.tools.delete(File.basename(f, ".rb")) if growth
      load f
    rescue StandardError => e
      warn "rubyclaw: skipping #{File.basename(f)} (#{e.class}: #{e.message})"
    ensure
      RubyClaw.current_origin = nil
    end
  end
end
