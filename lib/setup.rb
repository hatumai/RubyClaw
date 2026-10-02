# frozen_string_literal: true
# First-run setup. Two questions and the harness is usable: which model to talk to,
# and (optionally) which Telegram bot to answer on.
#
# Everything a secret is asked for goes to .env, which is chmod 600 and gitignored.
# Everything else goes to config.yml, which is meant to be read and edited. Nothing
# is written until the endpoint has answered a real request, so a typo in a key or a
# base URL is caught here rather than on the first task.
require_relative "boot"
require_relative "harness"
require_relative "notes"
require "io/console"
require "yaml"

module RubyClaw
  module Setup
    PROVIDERS = [
      { name: "DeepSeek", url: "https://api.deepseek.com/v1", model: "deepseek-chat",
        note: "cheap, good at tool calls" },
      { name: "OpenRouter", url: "https://openrouter.ai/api/v1", model: nil,
        note: "one key, hundreds of models" },
      { name: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini", note: "" },
      { name: "Groq", url: "https://api.groq.com/openai/v1", model: nil, note: "fast, free tier" },
      { name: "Together", url: "https://api.together.xyz/v1", model: nil, note: "" },
      { name: "A local server", url: "http://127.0.0.1:11434/v1",
        model: nil, note: "Ollama / LM Studio / llama.cpp; no key" },
      { name: "Something else", url: nil, model: nil, note: "any OpenAI-compatible base URL" }
    ].freeze

    ENV_FILE    = File.join(ROOT, ".env")
    CONFIG_FILE = File.join(ROOT, "config.yml")
    MANAGED_ENV = %w[CLAW_API_KEY CLAW_TELEGRAM_TOKEN].freeze

    class << self
      # A harness with a working endpoint and no first-run flag still counts as
      # configured — that covers the case where someone sets CLAW_* and never runs
      # the wizard at all.
      def needed?
        return false if RubyClaw.config["setup_complete"]
        return false if ENV["CLAW_SKIP_SETUP"].to_s == "1"
        url = RubyClaw.base_url.to_s
        return true if url.empty?
        return false if local?(url)              # a local server needs no key
        RubyClaw.api_key.to_s.empty?
      end

      def say(s = "") = @out.puts(s)

      # Returns :serve (Telegram + local prompt), :chat (local only) or :exit.
      def run(input: $stdin, output: $stdout, non_interactive: false, force_tty: false)
        @in = input
        @out = output
        @force_tty = force_tty
        header
        return from_env if non_interactive || !(tty? || force_tty)
        provider = ask_provider
        model    = ask_model(provider)
        unless verify!(model, provider[:url])
          say "\n  No answer from that endpoint, so nothing has been written. Fix the key or\n" \
              "  the base URL and run `claw setup` again."
          return :exit
        end
        chat_id = configure_telegram
        write!(model, provider[:url], chat_id)
        default_action(chat_id)
      end

      def from_env
        model = ENV["CLAW_MODEL"].to_s
        url   = ENV["CLAW_BASE_URL"].to_s
        raise Error, "non-interactive setup needs CLAW_MODEL and CLAW_BASE_URL in the environment" if model.empty? || url.empty?
        unless ENV["CLAW_API_KEY"].to_s.empty? || local?(url)
          warn "= using CLAW_API_KEY from the environment"
        end
        unless verify!(model, url, attempts: 1)
          raise Error, "that endpoint did not answer — check CLAW_BASE_URL and CLAW_API_KEY"
        end
        @pending_key = ENV["CLAW_API_KEY"] unless ENV["CLAW_API_KEY"].to_s.empty?
        @pending_token = ENV["CLAW_TELEGRAM_TOKEN"] unless ENV["CLAW_TELEGRAM_TOKEN"].to_s.empty?
        # Every id, not just the first: the allowlist was silently truncated, so a bot
        # configured for two chats answered one of them and ignored the other.
        allowed = ENV["CLAW_TELEGRAM_ALLOWED"].to_s.split(",").map(&:strip).reject(&:empty?)
        write!(model, url, allowed)
        say "= wrote config.yml and .env"
        :exit
      end

      # ---- prompting ----------------------------------------------------------

      # tty? decides whether to prompt at all (--interactive can force it);
      # real_tty? decides whether input can be hidden, which needs a real terminal.
      def tty? = real_tty? || @force_tty == true
      def real_tty? = @in.respond_to?(:tty?) && @in.tty?

      def gets_line
        line = @in.gets
        raise Error, "input ended — run `claw setup` from a terminal, or set CLAW_MODEL/" \
                     "CLAW_BASE_URL/CLAW_API_KEY in the environment" if line.nil?
        line.chomp.strip
      end

      def ask(question, default: nil)
        @out.print "  #{question}#{default ? " [#{default}]" : ""}: "
        @out.flush
        a = gets_line
        a.empty? && default ? default : a
      end

      def ask_yn(question, default: true)
        a = ask("#{question} (y/n)", default: default ? "y" : "n").downcase
        %w[y yes].include?(a)
      end

      def secret(question)
        @out.print "  #{question}: "
        @out.flush
        if real_tty? && @in.respond_to?(:getpass)
          v = @in.getpass("")          # io/console: echo off for a real terminal
          @out.puts
          v.to_s.strip
        else
          gets_line
        end
      end

      def choose(title, items, default: 1)
        say "#{title}:"
        width = [items.map { |it| it[:name].length }.max.to_i, 30].max + 2
        items.each_with_index do |it, i|
          say format("  %d) %-#{width}s %s", i + 1, it[:name], it[:note].to_s)
        end
        loop do
          a = ask("number or name", default: default.to_s)
          return items[a.to_i - 1] if a.to_i.between?(1, items.size)
          hit = items.find { |it| it[:name].downcase.include?(a.downcase) }
          return hit if hit
          say "  ...not one of those. Try 1-#{items.size}."
        end
      end

      # ---- steps --------------------------------------------------------------

      def header
        say "\nRubyClaw setup — a model endpoint, and optionally a Telegram bot."
        say "Enter accepts the default. Secrets go to .env (chmod 600, gitignored)."
      end

      def ask_provider
        say ""
        # OpenRouter is the default because it has a free tier that needs no card: press
        # Enter here and a new install has a working model without paying for anything.
        p = choose("endpoint", PROVIDERS,
                   default: (PROVIDERS.index { |x| x[:name] == "OpenRouter" } || 0) + 1)
        if p[:url].nil?
          p = p.merge(url: ask("base URL (e.g. https://host/v1)"))
          raise Error, "a base URL is required" if p[:url].to_s.empty?
        end
        say "  → #{p[:url]}"
        p = p.merge(keyless: local?(p[:url]))
        p
      end

      def local?(url) = url.to_s.match?(%r{\Ahttps?://(127\.0\.0\.1|localhost|\[::1\])(:|\z)})

      def ask_model(provider)
        hint = provider[:keyless] ? " (Enter to skip — a local server usually needs none)" : " (input hidden)"
        key = secret("api key for #{provider[:name]}#{hint}")
        @pending_key = key unless key.to_s.empty?
        if !provider[:keyless] && key.to_s.empty?
          say "  no key: most hosted endpoints will refuse. You can add CLAW_API_KEY to .env later."
        end
        if provider[:name] == "OpenRouter" && key.to_s.empty?
          say "  a key is free to make at https://openrouter.ai/keys — free models need no card."
        end
        ids = list_models(provider[:url], key)
        if ids.any?
          # Free first. On a gateway like OpenRouter the list is long and alphabetical,
          # so whatever sorts first is arbitrary -- and a new install should land on
          # something that costs nothing. Anything with ":free" in the name is free.
          ordered = ids.partition { |m| m.to_s.include?(":free") }.flatten
          say "  endpoint offers #{ids.size} model#{ids.size == 1 ? '' : 's'}:"
          ordered.first(10).each_with_index do |m, i|
            say format("    %2d) %s%s", i + 1, m, m.to_s.include?(":free") ? "   (free)" : "")
          end
          loop do
            a = ask("model (name or number)", default: provider[:model] || ordered.first)
            model = a.to_i.between?(1, [ids.size, 12].min) ? ordered[a.to_i - 1] : a
            return model unless model.to_s.empty?
          end
        end
        loop do
          m = ask("model name", default: provider[:model])
          return m unless m.to_s.empty?
          say "    ...a model name is required."
        end
      end

      # Ask the endpoint what it has. A failure here is not fatal — plenty of
      # gateways do not implement /models — it just means the name is typed.
      def list_models(url, key)
        uri = URI("#{url}/models")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{key}" unless key.to_s.empty?
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10,
                              read_timeout: 20) { |h| h.request(req) }
        return [] unless res.code.to_i == 200
        data = begin
          JSON.parse(res.body)
        rescue StandardError
          nil
        end
        return [] unless data.is_a?(Hash)
        Array(data["data"]).map { |m| m["id"].to_s }.reject(&:empty?).sort
      rescue StandardError
        []
      end

      # The important one: a real request, before anything is written.
      def verify!(model, url, attempts: 3)
        say "  checking it answers..."
        attempts.times do |i|
          RubyClaw.override!(model: model, base_url: url, api_key: @pending_key)
          t0 = Time.now
          begin
            r = RubyClaw.chat_once([{ "role" => "user", "content" => "Reply with exactly one word: ready" }],
                                   max_tokens: 24)
            say format("  ok — %s said %p in %.1fs", model, r["content"].to_s.strip[0, 40], Time.now - t0)
            return true
          rescue StandardError => e
            say "  ✗ #{e.message.to_s.split("\n").first[0, 160]}"
            return false if i == attempts - 1
            say "  (check the key and the base URL; #{attempts - i - 1} more attempt(s))"
          end
        end
        false
      end

      # ---- telegram -----------------------------------------------------------

      def configure_telegram
        return nil unless ask_yn("\nconnect a Telegram bot (optional)", default: false)
        say "  make one: in Telegram, message @BotFather, send /newbot, copy the token"
        token = secret("bot token (input hidden)")
        @pending_token = token unless token.to_s.empty?
        acct = tg(token, "getMe")
        raise Error, "that token did not work: #{acct.inspect[0, 120]}" if acct.is_a?(String)
        say "  connected as @#{acct['username']}"
        chat_id = discover_chat(token, acct["username"])
        chat_id
      end

      # getUpdates with a short timeout; the first message teaches us the id. The bot
      # refuses unknown chats, so this is the one moment it is useful to be refused.
      def discover_chat(token, username)
        say "\n  now open https://t.me/#{username} and send it anything"
        say "  (it will refuse — that refusal is how it learns your id)"
        offset, deadline = 0, Time.now + 90
        while Time.now < deadline
          upd = tg(token, "getUpdates", { offset: offset, timeout: 10 })
          Array(upd).each do |u|
            offset = u["update_id"].to_i + 1
            msg = u["message"] || u["edited_message"] or next
            chat = msg["chat"] || {}
            who  = msg.dig("from", "username") || msg.dig("from", "first_name") ||
                   chat["title"] || "?"
            id = chat["id"]
            say "\n  message from #{who} — chat id #{id}"
            if ask_yn("  allow that chat", default: true)
              return id
            end
          end
          print "."
          $stdout.flush if $stdout.respond_to?(:flush)
        end
        say "\n  no message arrived."
        loop do
          id = ask("chat id to allow (or Enter to skip)", default: "")
          return nil if id.empty?
          return id.to_i if id.to_i.positive?
          say "    ...a chat id is a number like 1487339123."
        end
      end

      # Same seam as the adapter, so the wizard can be exercised against
      # scripts/tg_stub.rb without a real bot token.
      def tg_base = ENV["CLAW_TELEGRAM_API_BASE"] || "https://api.telegram.org"

      def tg(token, method, params = nil)
        uri = URI("#{tg_base}/bot#{token}/#{method}")
        req = params ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        if params
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(params)
        end
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10,
                              read_timeout: 25) { |h| h.request(req) }
        data = begin
          JSON.parse(res.body)
        rescue StandardError
          nil
        end
        return "HTTP #{res.code}" unless data.is_a?(Hash)
        data["ok"] ? data["result"] : (data["description"] || "HTTP #{res.code}")
      rescue StandardError => e
        e.message
      end

      # ---- write --------------------------------------------------------------

      def write!(model, url, chat_id)
        say "\n  writing config"
        env = existing_env
        wrote = []
        { "CLAW_API_KEY" => @pending_key, "CLAW_TELEGRAM_TOKEN" => @pending_token }.each do |k, v|
          next if v.to_s.empty?
          env[k] = v
          ENV[k] = v
          wrote << k
        end
        write_env(env) if wrote.any?

        # safe_load_file, matching boot.rb: this file is rewritten in place, and the
        # plain loader will instantiate arbitrary objects from YAML tags.
        cfg = begin
          YAML.safe_load_file(CONFIG_FILE) || {}
        rescue StandardError
          {}                                       # a corrupt config is rebuilt, not fatal
        end
        cfg = {} unless cfg.is_a?(Hash)
        cfg.delete("api_key")                      # never keep a secret in config.yml
        ids = Array(chat_id).flatten.map { |c| c.to_s.strip }.reject(&:empty?).map(&:to_i).uniq
        cfg["model"] = model
        cfg["base_url"] = url
        cfg["telegram_allowed_chat_ids"] = ids
        cfg["setup_complete"] = true
        ENV["CLAW_TELEGRAM_ALLOWED"] = ids.join(",")
        write_atomic(CONFIG_FILE, header_comment + YAML.dump(cfg))
        Notes.ensure!          # preferences.md, memory.md, skills/ exist from the start
        RubyClaw.reload_config!

        say "  config.yml  model=#{model}, base_url=#{url}" \
            "#{ids.any? ? ", allowed chat #{ids.join(', ')}" : ''}"
        say "  .env        #{wrote.empty? ? '(unchanged — the key came from your environment)' : wrote.join(', ') + ' (chmod 600)'}"
        chmod_env if File.exist?(ENV_FILE)         # also repairs a pre-existing 0644 .env
      end

      def header_comment
        <<~HEAD
          # RubyClaw configuration. Written by `claw setup`; safe to edit.
          # Resolution order for each value: CLI flag > environment > this file.
          # Secrets do NOT belong here (this file is tracked by git) — they live in .env.
        HEAD
      end

      def existing_env
        out = {}
        if File.exist?(ENV_FILE)
          File.readlines(ENV_FILE).each do |l|
            k, v = l.strip.split("=", 2)
            out[k] = v if k.to_s.match?(/\A[A-Z_][A-Z0-9_]*\z/) && v
          end
        end
        out
      end

      def write_env(env)
        body = +"# RubyClaw secrets. chmod 600, gitignored. Never commit this file.\n"
        env.each { |k, v| body << "#{k}=#{v}\n" }
        # Writing the file and chmod-ing it afterwards left a window (and a crash left it
        # permanent): under a loose umask the fresh .env was 0664 — readable by every
        # user on the machine — until the chmod ran. Create it 0600 from the start.
        write_atomic(ENV_FILE, body, mode: 0o600)
      end

      # Same directory (so the rename stays on one filesystem), 0600/0644 from birth,
      # then rename: a reader sees the old file or the new one, never half of either.
      def write_atomic(path, body, mode: 0o644)
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.tmp")
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(body) }
        File.chmod(mode, tmp)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def chmod_env = File.chmod(0o600, ENV_FILE)

      def default_action(chat_id)
        opts = []
        opts << { name: "Telegram bot + a local prompt here (leave it running)", note: "", key: :serve } if chat_id
        opts << { name: "Just chat here in this terminal", note: "", key: :chat }
        opts << { name: "Nothing — I'll start it later with ./rubyclaw", note: "", key: :exit }
        choose("  how do you want to run it", opts, default: 1)[:key]
      end
    end
  end
end
