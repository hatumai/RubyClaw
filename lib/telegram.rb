# frozen_string_literal: true
# Telegram adapter: long-polling, stdlib only (no gem, no webhook, no open port).
#
# Design notes that matter:
# - Long polling, not webhooks. A Pi behind a home router has no inbound port, and
#   long polling needs no TLS cert, no reverse proxy, and no firewall change.
# - The bot is useless-and-harmless until it is told who may talk to it. With no
#   allowlist, every message gets a refusal that echoes the chat id, which is how
#   you learn your own id without guessing or asking anyone.
# - One conversation per chat, held in memory. /new drops it. This is a
#   deliberately single-threaded loop: one task at a time, in order.
require_relative "harness"
require_relative "consolidate"
require_relative "work"

module RubyClaw
  class Telegram
    MAX_MSG = 4000          # Telegram's hard limit is 4096; leave room for a marker
    POLL_TIMEOUT = 50       # seconds the server holds an empty long-poll open
    MAX_FAILURES = 6        # consecutive failed polls before giving up (~3 min of backoff)

    # ---- inline approvals -------------------------------------------------
    #
    # A parked approval reaches a person as a message with two buttons. A tap comes back
    # as a callback_query carrying only callback_data, so the approval id and the intent
    # travel in that string -- and Telegram caps callback_data at 64 bytes. The format is
    # "approve:<approval_id>" / "deny:<approval_id>"; ids are short ("ap-" + 12 hex), so
    # the payload is ~23 bytes and stays well inside the limit.
    CALLBACK_APPROVE = "approve"
    CALLBACK_DENY    = "deny"
    CALLBACK_LIMIT   = 64   # Telegram's own limit on callback_data, in bytes
    # Intent -> the decision `claw work decide` records. Read as data so an unknown
    # intent is refused rather than guessed.
    APPROVAL_DECISIONS = { CALLBACK_APPROVE => "granted", CALLBACK_DENY => "denied" }.freeze

    # Overridable so a test can reach the give-up path without sitting through three minutes of
    # backoff. Nothing else changes: giving up is safe because the keeper restarts the bot.
    def max_failures = [(ENV["CLAW_TG_MAX_FAILURES"] || MAX_FAILURES).to_i, 1].max

    # Where the next getUpdates starts. Persisted, because the alternative is worse than
    # it looks: Telegram confirms everything below the offset you ask with, so a process
    # that died after answering but before its next poll would answer the same message
    # again after a reboot -- and after a *reboot* is exactly when nobody is watching.
    # Overridable so a test does not write the project's own data/ (CLAW_TELEGRAM_OFFSET).
    OFFSET_FILE = if ENV["CLAW_TELEGRAM_OFFSET"].to_s.empty?
                    File.join(ROOT, "data", "telegram.offset")
                  else
                    File.expand_path(ENV["CLAW_TELEGRAM_OFFSET"])
                  end

    def initialize(token: nil, allowed: nil, model: nil, base_url: nil, api_key: nil)
      @token    = token || self.class.token
      @allowed  = (allowed || self.class.allowed_chats).map(&:to_i)
      @model    = model
      @base_url = base_url
      @api_key  = api_key
      @sessions = {}
      @offset   = self.class.saved_offset
    end

    def self.saved_offset
      return 0 unless File.exist?(OFFSET_FILE)

      File.read(OFFSET_FILE).to_i
    rescue SystemCallError
      0
    end

    # Written after every update, not on exit: a reboot does not get to run an at_exit.
    def save_offset
      FileUtils.mkdir_p(File.dirname(OFFSET_FILE))
      tmp = "#{OFFSET_FILE}.#{Process.pid}.tmp"
      File.write(tmp, "#{@offset}\n")
      File.rename(tmp, OFFSET_FILE)
    rescue SystemCallError
      nil      # losing the offset costs a duplicate reply, never a crash
    end

    def self.token
      t = ENV["CLAW_TELEGRAM_TOKEN"] || RubyClaw.config["telegram_token"]
      if t.to_s.empty?
        raise Error, "no Telegram token. Create a bot with @BotFather in Telegram, then put:\n" \
                     "  CLAW_TELEGRAM_TOKEN=<token>\n" \
                     "in #{File.join(ROOT, '.env')} (chmod 600). The token is never read from chat."
      end
      t
    end

    def self.allowed_chats
      cfg = RubyClaw.config["telegram_allowed_chat_ids"]
      from_env = ENV["CLAW_TELEGRAM_ALLOWED"].to_s.split(",")
      (Array(cfg) + from_env).map { |s| s.to_s.strip }.reject(&:empty?)
    end

    # Test seam: point the adapter at a fake Telegram during development.
    def self.api_base = ENV["CLAW_TELEGRAM_API_BASE"] || "https://api.telegram.org"

    # ---- the inline keyboard, as data -------------------------------------

    def self.callback_data(intent, id) = "#{intent}:#{id}"

    # [intent, approval_id], or nil when the string is not one of ours. Never raises:
    # arbitrary bytes can arrive in callback_data from an old message or another bot, and
    # a poll loop must not die on one.
    def self.parse_callback(data)
      s = data.to_s
      return nil if s.empty? || s.bytesize > CALLBACK_LIMIT

      intent, id = s.split(":", 2)
      return nil unless APPROVAL_DECISIONS.key?(intent) && !id.to_s.empty?

      [intent, id]
    end

    # The reply_markup for a parked approval: two buttons, one row.
    def self.approval_keyboard(approval_id)
      { "inline_keyboard" => [[
        { "text" => "Approve", "callback_data" => callback_data(CALLBACK_APPROVE, approval_id) },
        { "text" => "Deny", "callback_data" => callback_data(CALLBACK_DENY, approval_id) }
      ]] }
    end

    # A present-but-empty keyboard, so an edited message visibly spends its buttons.
    def self.spent_keyboard
      { "inline_keyboard" => [] }
    end

    def api(method, params = nil, timeout: 70)
      uri = URI("#{self.class.api_base}/bot#{@token}/#{method}")
      req = params ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      if params
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(params)
      end
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 15, read_timeout: timeout) { |h| h.request(req) }
      data = (JSON.parse(res.body) rescue nil)
      raise Error, "telegram #{method}: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless data.is_a?(Hash)
      raise Error, "telegram #{method}: #{data['description']}" unless data["ok"]
      data["result"]
    end

    def fetch_updates
      api("getUpdates",
          { offset: @offset, timeout: POLL_TIMEOUT,
            allowed_updates: %w[message edited_message callback_query] },
          timeout: POLL_TIMEOUT + 25)
    end

    def run(max_polls: nil)
      me = api("getMe")
      warn "rubyclaw: bot @#{me['username']} connected"
      warn if @allowed.empty?
      warn @allowed.empty? ? "rubyclaw: NO allowlist — every chat is refused (your chat id appears in the refusal)" :
                             "rubyclaw: allowed chats #{@allowed.join(', ')}"
      polls = 0
      failures = 0
      loop do
        begin
          handle(fetch_updates)
          failures = 0
        rescue Error, SystemCallError, IOError, Timeout::Error => e
          # A dropped connection used to propagate: under `claw up` the bot thread died
          # with only a stderr line to say so, and under `claw telegram` the process
          # aborted. Back off and keep listening; only give up if it never recovers.
          failures += 1
          raise if failures > max_failures

          warn "rubyclaw: poll failed (#{failures}/#{max_failures}): #{e.class}: #{e.message}"
          sleep [2**failures, 30].min
        end
        polls += 1
        break if max_polls && polls >= max_polls
      end
      polls
    rescue Interrupt
      warn "\nrubyclaw: stopped"
      polls
    end

    def handle(updates)
      Array(updates).each do |u|
        @offset = u["update_id"].to_i + 1
        if (cb = u["callback_query"])
          handle_callback(cb)
        else
          msg = u["message"] || u["edited_message"]
          next unless msg

          handle_message(msg)
        end
        save_offset
      rescue StandardError => e
        warn "rubyclaw: update failed: #{e.class}: #{e.message}"
        save_offset      # the update was consumed either way: do not replay it forever
      end
    end

    # fetch_updates must start where the last run finished.
    def offset = @offset

    def handle_message(msg)
      chat_id = msg.dig("chat", "id")
      text = msg["text"].to_s
      from = msg.dig("from", "username") || msg.dig("from", "first_name") || "?"

      unless @allowed.include?(chat_id)
        warn "rubyclaw: refused #{from} (chat #{chat_id})"
        send_message(chat_id, "Not configured to talk to chat #{chat_id}.\n" \
                              "Add that id to telegram_allowed_chat_ids in config.yml " \
                              "(or CLAW_TELEGRAM_ALLOWED=#{chat_id} in .env) and restart.")
        return
      end

      if text.empty?
        send_message(chat_id, "I can only read text for now.")
        return
      end

      return handle_command(chat_id, text.strip) if text.start_with?("/")

      warn "rubyclaw: #{from}: #{text[0, 90]}"
      send_action(chat_id, "typing")
      session = (@sessions[chat_id] ||= Harness.new(model: @model, base_url: @base_url,
                                                    api_key: @api_key, quiet: true))
      answer = session.run(text).to_s
      send_message(chat_id, answer.empty? ? "(no answer)" : answer)
      warn "rubyclaw: replied #{answer.bytesize}B | #{session.usage_line}"
    end

    # A tap on an Approve/Deny button. The chat is checked against the allowlist FIRST --
    # an unknown chat must not be able to decide an approval by replaying a callback id.
    # That is the same rule handle_message enforces, and a missing check here would let
    # anyone who guessed an approval id grant it. The decision then goes through
    # Work.decide_approval, the one path `claw work decide` uses, so the buttons and the
    # CLI cannot drift apart -- and a tap is a person's act, not the agent's, so the
    # work.decide policy (human_only for the model) does not apply to it.
    def handle_callback(cb)
      chat_id = cb.dig("message", "chat", "id")
      from = cb.dig("from", "username") || cb.dig("from", "first_name") || "?"
      unless @allowed.include?(chat_id)
        warn "rubyclaw: refused callback from #{from} (chat #{chat_id})"
        answer_callback(cb["id"], "Not configured to talk to chat #{chat_id}.")
        return
      end

      parsed = self.class.parse_callback(cb["data"])
      decision = parsed && APPROVAL_DECISIONS[parsed[0]]
      unless decision
        warn "rubyclaw: ignored callback with unrecognised data #{cb['data'].to_s[0, 40].inspect}"
        answer_callback(cb["id"], "Unrecognised action.")
        return
      end

      begin
        Work.decide_approval(parsed[1], decision, by: "telegram:#{from}")
        answer_callback(cb["id"], decision == "granted" ? "Approved" : "Denied")
        finish_approval_message(cb, decision == "granted" ? "✅ Approved by #{from}" : "🚫 Denied by #{from}")
      rescue Error => e
        # Already decided, or a callback naming no approval. Say so on the toast and mark
        # the message spent, but never let a stale button take down the poll loop.
        answer_callback(cb["id"], e.message)
        finish_approval_message(cb, "⚠️ #{e.message}")
      rescue StandardError => e
        warn "rubyclaw: callback failed: #{e.class}: #{e.message}"
        answer_callback(cb["id"], "Could not record the decision.")
      end
    end

    # Edit the message that carried the buttons so it shows the outcome and the buttons
    # are gone. The last chunk is the right one: that is where the buttons were.
    def finish_approval_message(cb, outcome)
      message = cb["message"] || {}
      chat_id = message.dig("chat", "id")
      message_id = message["message_id"]
      return unless chat_id && message_id

      body = strip_outcome(message["text"].to_s)
      api("editMessageText", { chat_id: chat_id, message_id: message_id,
                               text: "#{body}\n\n#{outcome}",
                               reply_markup: self.class.spent_keyboard })
    rescue StandardError => e
      warn "rubyclaw: could not edit the approval message: #{e.class}: #{e.message}"
    end

    # Drop a status line a previous tap appended, so a second tap (or a stale button)
    # does not stack outcomes on top of each other.
    def strip_outcome(text)
      text.to_s.split(/\n\n(?=[✅🚫⚠️])/, 2).first.to_s
    end

    def answer_callback(callback_id, text = nil)
      return if callback_id.to_s.empty?

      params = { callback_query_id: callback_id }
      params[:text] = text unless text.to_s.empty?
      api("answerCallbackQuery", params)
    rescue StandardError => e
      warn "rubyclaw: answerCallbackQuery failed: #{e.class}: #{e.message}"
    end

    def handle_command(chat_id, cmd)
      case cmd.split(" ").first
      when "/new", "/start"
        @sessions.delete(chat_id)
        send_message(chat_id, "New conversation. #{RubyClaw.tools.size} tools: " \
                              "#{RubyClaw.tools.keys.join(', ')}")
      when "/tools"
        send_message(chat_id, RubyClaw.tools.map { |n, t|
          "#{n} [#{t.origin == 'builtin' ? 'core' : 'self'}]"
        }.join("\n"))
      when "/stats"
        inv = Consolidate.inventory
        rows = [format("%-16s %5s %5s %7s", "tool", "calls", "errs", "idle")] +
               inv.map { |t| format("%-16s %5d %5d %7s", t["name"], t["calls"], t["errors"],
                                    t["idle_days"] ? "#{t['idle_days']}d" : "never") }
        send_message(chat_id, rows.join("\n"))
      when "/model"
        send_message(chat_id, "model    #{@model || RubyClaw.model_name}\n" \
                              "endpoint #{@base_url || RubyClaw.base_url}\n" \
                              "key      #{RubyClaw.api_key.to_s.empty? ? 'NOT SET' : 'set (' + RubyClaw.key_source + ')'}")
      when "/prefer", "/remember"
        text = cmd.split(" ", 2)[1].to_s
        send_message(chat_id, text.empty? ? "usage: /prefer <how you want me to work>" :
                                            Notes.append(:preference, text))
      when "/notes"
        Notes.ensure!
        send_message(chat_id, Notes::FILES.map { |k, p| "#{File.basename(p)}: #{Notes.read(k).lines.size} line(s)" }
                                     .join("\n") +
                              "\nskills: #{Notes.skill_files.size}")
      when "/help", "/?"
        send_message(chat_id, "/new  fresh conversation\n/prefer <text>  remember a preference\n" \
                              "/notes  what it has learned\n/tools  tool surface\n" \
                              "/stats  tool usage\n/model  resolved model + endpoint")
      else
        send_message(chat_id, "commands: /new /prefer /notes /tools /stats /model")
      end
    end

    def send_message(chat_id, text, reply_markup: nil)
      send_chunks(chat_id, text, reply_markup: reply_markup)
    rescue StandardError => e
      warn "rubyclaw: send failed: #{e.class}: #{e.message}"
    end

    # Send `text` in as many messages as the 4096-unit limit requires, with `reply_markup`
    # on the LAST one only: the buttons belong under the end of the message. Putting the
    # keyboard on an earlier chunk would leave the rest of the text below it and read as
    # if the message had ended. Raises on failure (unlike send_message) so a caller that
    # must not lose the message -- the notification queue -- can keep and retry it.
    def send_chunks(chat_id, text, reply_markup: nil)
      parts = chunk(text.to_s)
      last = parts.size - 1
      parts.each_with_index do |part, i|
        params = { chat_id: chat_id, text: part, disable_web_page_preview: true }
        params[:reply_markup] = reply_markup if reply_markup && i == last
        api("sendMessage", params)
      end
      parts.size
    end

    # A parked approval as a person reads it: the body, then Approve/Deny on the last chunk.
    def send_approval(chat_id, approval_id, text)
      send_chunks(chat_id, text, reply_markup: self.class.approval_keyboard(approval_id))
    end

    def send_action(chat_id, action)
      api("sendChatAction", { chat_id: chat_id, action: action })
    rescue StandardError
      nil
    end

    # Telegram rejects anything over 4096, counted in UTF-16 code units — so an emoji
    # costs two. Ruby's String#length counts characters, which is why a long line of
    # emoji was sent as "one chunk" of 4000 and rejected outright. Split on line
    # boundaries, and flush what came before *before* slicing an over-long line: the
    # pieces used to be appended ahead of the earlier lines, so a long line arrived
    # before the text that preceded it.
    def chunk(text, limit = MAX_MSG)
      out = []
      buf = +""
      text.to_s.each_line do |line|
        while units(line) > limit
          out << buf unless buf.empty?
          buf = +""
          piece = take_units(line, limit)
          out << piece
          line = line[piece.length..].to_s
        end
        if units(buf) + units(line) > limit
          out << buf unless buf.empty?
          buf = +""
        end
        buf << line
      end
      out << buf unless buf.empty?
      out.empty? ? [""] : out
    end

    def units(s) = s.to_s.encode(Encoding::UTF_16BE).bytesize / 2

    # The longest prefix of `s` that fits in `limit` UTF-16 units, never splitting a
    # character in half.
    def take_units(s, limit)
      used = 0
      s.each_char.with_index do |c, i|
        cost = c.ord > 0xFFFF ? 2 : 1
        return s[0, i] if used + cost > limit

        used += cost
      end
      s
    end
  end
end
