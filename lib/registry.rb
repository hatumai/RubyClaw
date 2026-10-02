# frozen_string_literal: true
# Tool registry. A tool is a name, a description, a JSON-schema param map, and a
# block. Self-written code registers tools with the same call the builtins use —
# there is no privileged path, which is the whole point.
#
# Every call passes the autonomy policy (lib/policy.rb) before the block runs: the
# policy file decides auto | ask | block | human_only for the action the tool maps to,
# and `ask`/`block`/`human_only` stop here, before anything happens. A model-issued
# call is never allowed to run by default -- an action no rule covers is `ask`.
require_relative "policy"
module RubyClaw
  Tool = Struct.new(:name, :description, :params, :required, :block, :origin, keyword_init: true)

  @tools = {}
  @order = []
  # Set by boot.rb around each dynamic load, so a self-written tool is labelled
  # as such instead of masquerading as core.
  @current_origin = nil

  class << self
    def tools = @tools
    def order = @order
    attr_accessor :current_origin

    # origin: "builtin" or the path of the self-written file that registered it
    def tool(name, description:, params: {}, origin: nil, replace: false, &blk)
      origin ||= @current_origin || "builtin"
      name = name.to_s
      raise Error, "no block given for tool #{name}" unless blk
      if @tools.key?(name) && !replace
        raise Error, "tool #{name} is already registered"
      end
      @order << name unless @tools.key?(name)
      props, required = split_required(deep_stringify(params))
      @tools[name] = Tool.new(name: name, description: description, params: props,
                              required: required, block: blk, origin: origin)
      @tools[name]
    end

    # JSON Schema puts `required` on the object, as an array of names — but writing
    # it on the parameter itself is a natural mistake, and it is the *intent* that
    # matters. Accept it: move it up. A per-parameter required:false makes the
    # parameter optional. Anything else malformed is still left for the validator
    # to reject rather than silently repaired.
    def split_required(params)
      props = {}
      required = []
      params.each do |k, v|
        v = v.dup if v.is_a?(Hash)
        if v.is_a?(Hash)
          r = v.delete("required")
          required << k unless r == false || r.to_s == "false"
        else
          required << k
        end
        props[k.to_s] = v
      end
      [props, required]
    end

    # Self-written tools are written by a language model, which will use symbol
    # keys about a third of the time. Accept both rather than rejecting valid code.
    def deep_stringify(o)
      case o
      when Hash  then o.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array then o.map { |v| deep_stringify(v) }
      else o
      end
    end

    # Builtins first (frozen order), then self-written tools in load order.
    # Append-only: a new tool never reorders the ones already cached upstream.
    def schemas
      @order.filter_map { |n| @tools[n] }.map do |t|
        {
          type: "function",
          function: {
            name: t.name,
            description: t.description,
            parameters: {
              type: "object",
              properties: t.params.empty? ? {} : t.params,
              required: t.required
            }
          }
        }
      end
    end

    # Blocks may take a Hash (generic) or keywords. Support both, since the model
    # writes them and shouldn't have to remember which one the harness prefers.
    def invoke(tool, args)
      args = (args || {}).transform_keys(&:to_s)
      blk = tool.block
      if blk.parameters.any? { |kind, _| kind == :key || kind == :keyreq || kind == :keyrest }
        blk.call(**args.transform_keys(&:to_sym))
      else
        blk.call(args)
      end
    end

    # `internal` marks a call the harness's own code makes -- the A/B replay in
    # child_ab.rb replays calls that already happened -- rather than one a model asked
    # for. The untrusted actor is the model, so the policy gate covers every call that
    # came from it and skips the harness's own.
    def call(name, args, internal: false)
      t = @tools[name.to_s]
      return "ERROR: no such tool #{name}. Registered: #{@order.join(', ')}" unless t
      unless internal
        verdict = RubyClaw::Policy.check(t.name, args)
        return truncate(RubyClaw.utf8(verdict["message"])) unless verdict["run"]
      end

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = invoke(t, args)
      s = RubyClaw.utf8(out.is_a?(String) ? out : JSON.generate(out))
      record_usage(t.name, args, s, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, ok: true)
      truncate(s)
    rescue SystemExit => e
      # A tool that calls exit/abort -- or a self-written tool with a stray `exit` on a
      # failure path -- took the whole harness down with it (measured: a tool's `exit 9`
      # ended the process with status 9, mid-conversation, with no error to the model).
      msg = RubyClaw.utf8("ERROR (SystemExit): the tool tried to exit the process (status " \
                          "#{e.status}); a tool must return, not exit. Nothing else ran.")
      record_usage(name.to_s, args, msg, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, ok: false) if t0
      msg
    rescue StandardError => e
      msg = RubyClaw.utf8("ERROR (#{e.class}): #{e.message}\n#{Array(e.backtrace).first(4).join("\n")}")
      record_usage(name.to_s, args, msg, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, ok: false) if t0
      msg
    end

    # Cut on a character boundary. byteslice(0, MAX_OUT) can split a multibyte
    # character, and invalid UTF-8 makes JSON.generate raise on the way out — which
    # kills that request and every request after it, because the poisoned tool
    # result stays in the conversation until /new.
    def truncate(s)
      return s if s.bytesize <= MAX_OUT

      "#{RubyClaw.utf8(s.byteslice(0, MAX_OUT))}\n…[truncated #{s.bytesize - MAX_OUT} bytes]"
    end

    # Every call is recorded. This log is the harness's only source of evidence
    # about itself: which tools earn their place, which silently error, and which
    # real arguments a tool was actually exercised with (the regression corpus
    # consolidation replays before it retires anything).
    def record_usage(name, args, out, secs, ok: nil)
      return if ENV["CLAW_NO_USAGE"]
      File.open(File.join(LOG_DIR, "usage.jsonl"), "a") do |f|
        f.puts JSON.generate(ts: Time.now.iso8601, tool: name, ms: (secs * 1000).round,
                             bytes: out.bytesize, ok: ok.nil? ? !out.to_s.start_with?("ERROR") : ok,
                             args: redact(args))
      end
    rescue StandardError
      nil # telemetry must never break a tool call
    end

    # Tool args can carry credentials (an http call with an Authorization header,
    # an API key). Log the shape, not the secret.
    SECRET_KEY = /key|token|secret|password|passwd|authorization|auth|cookie/i

    # Field names are not enough. A credential in a query string or a JSON body sits
    # under a harmless name ("url", "body") in a log that gets replayed, read by the
    # consolidation audit, and committed — so the values get matched too.
    SECRET_VALUE = /
      \b(?:sk|rk|pk|gsk|hf|ghp|gho|ghu|glpat|xox[abprs])[-_][A-Za-z0-9_\-]{12,}
      |\bAIza[0-9A-Za-z_\-]{20,}
      |\bAKIA[0-9A-Z]{12,}
      |\bey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}
      |(?i:\b(?:api[_-]?key|access[_-]?token|token|secret|password)=)[^&\s"']{6,}
      |(?i:\bbearer\s+)[A-Za-z0-9._\-]{16,}
    /x

    # Public: the transcript writer and the transcript reader both use it.
    def redact_text(s) = RubyClaw.utf8(s).gsub(SECRET_VALUE) { "[redacted]" }

    def redact_text_deep(o)
      case o
      when Hash  then o.each_with_object({}) { |(k, v), h| h[k] = redact_text_deep(v) }
      when Array then o.map { |v| redact_text_deep(v) }
      when String then redact_text(o)
      else o
      end
    end

    def redact(o, depth = 0)
      return "[deep]" if depth > 4
      case o
      when Hash
        o.each_with_object({}) do |(k, v), h|
          h[k.to_s] = k.to_s.match?(SECRET_KEY) ? "[redacted]" : redact(v, depth + 1)
        end
      when Array then o.first(20).map { |v| redact(v, depth + 1) }
      when String then redact_text(o.length > 400 ? "#{o[0, 400]}…[#{o.length}]" : o)
      else o
      end
    end
  end
end
