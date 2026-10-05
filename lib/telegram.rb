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
require_relative "policy"
require "openssl"   # named on its own so a TLS failure is a class the poll loop can hold

module RubyClaw
  class Telegram
    MAX_MSG = 4000          # Telegram's hard limit is 4096; leave room for a marker
    POLL_TIMEOUT = 50       # seconds the server holds an empty long-poll open
    MAX_FAILURES = 6        # consecutive failed polls before a PERSON is told (the loop lives on)
    TYPING_REFRESH = 4      # Telegram's "typing…" expires after ~5s; refresh well inside that

    # A bad token is the one thing retrying cannot fix: HTTP 401/403 (or Telegram's own
    # Unauthorized/Forbidden) means the credential is wrong, so the poll loop stops and
    # says so instead of hammering the API forever. Everything else is transient.
    class AuthError < Error; end

    # Poll failures that mean "the network, again": retry them forever. This is the
    # reported bug -- an armv6 board whose TLS to api.telegram.org times out now and then
    # used to raise and exit after six failures, so the bot went silent with only a
    # stderr line to say why. A connection reset, a DNS blip, a 5xx or a 429 are all
    # here; a code bug is deliberately not, so a real fault still surfaces.
    TRANSIENT_ERRORS = [
      Error,                    # our own api() failure: a 5xx, 429, or a non-JSON body
      SystemCallError,          # ECONNREFUSED, ECONNRESET, EHOSTUNREACH...
      SocketError,              # DNS
      IOError, EOFError,
      Timeout::Error,           # Net::OpenTimeout, Net::ReadTimeout
      OpenSSL::SSL::SSLError    # a TLS handshake/read failure
    ].freeze

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

    # How many consecutive failed polls pass before a person is told the bot cannot
    # reach Telegram. It used to be the point at which the poller killed itself; it is
    # now the notification threshold, so the loop is never at its mercy. Overridable so a
    # test can reach the notice quickly without sitting through minutes of backoff.
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
      # A bad token is fatal, and only that. Telegram says it with 401/403 (and echoes
      # the words Unauthorized/Forbidden); catching it here, where the status still
      # exists, is what lets the poll loop stop cleanly instead of retrying a credential
      # that can never start working.
      if auth_failure?(res.code, data)
        raise AuthError, "telegram #{method}: HTTP #{res.code} " \
                         "#{data&.dig('description') || res.body.to_s[0, 200]}"
      end
      raise Error, "telegram #{method}: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless data.is_a?(Hash)
      raise Error, "telegram #{method}: #{data['description']}" unless data["ok"]
      data["result"]
    end

    def auth_failure?(code, data)
      return true if %w[401 403].include?(code.to_s)
      return true if data.is_a?(Hash) && %w[401 403].include?(data["error_code"].to_i.to_s)

      d = data.is_a?(Hash) ? data["description"].to_s : ""
      d.match?(/unauthorized|forbidden/i)
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
          # A clean poll clears the streak, so the backoff never ratchets up over a long
          # run of mostly-good polls, and the recovery notice below fires exactly once.
          failures = 0
          announce_recovered
        rescue AuthError => e
          # The one genuinely fatal condition: a bad token cannot start working by being
          # retried. Stop, and say exactly why in one line -- never die silently.
          warn "rubyclaw: stopping — Telegram rejected the credentials (#{e.message}); " \
               "fix CLAW_TELEGRAM_TOKEN and restart. A bad token cannot recover on its own."
          break
        rescue *TRANSIENT_ERRORS => e
          # A dropped or timed-out poll is not the end of the bot: back off, tell the
          # person once the streak is long enough (see announce_unreachable), and keep
          # listening forever. The reported bug was this raising and exiting at six.
          failures += 1
          warn "rubyclaw: poll failed (#{failures} in a row): #{e.class}: #{e.message}"
          announce_unreachable(failures)
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

    # ---- telling a person the bot is (un)reachable -------------------------
    #
    # Silence must not be indistinguishable from death. Once the streak crosses
    # max_failures, the allowlisted chat hears it once and only once, and again the
    # moment polls recover. The dedup is Notify's: the condition's key lives in the same
    # seen-ledger every other notification uses, so there is no second suppression flag
    # to drift out of sync. Re-arming the opposite key on each transition is what lets a
    # *later* outage be announced again instead of being deduped into silence forever.
    NOTICE_UNREACHABLE = "telegram:unreachable"
    NOTICE_RECOVERED   = "telegram:recovered"

    def announce_unreachable(failures)
      return if failures < max_failures

      n = notify_layer
      n.signal(NOTICE_UNREACHABLE,
               "⚠️ RubyClaw can't reach Telegram (#{failures} failed polls in a row). " \
               "Still trying — nothing needs doing. You'll hear from me the moment it's back.")
      n.rearm(NOTICE_RECOVERED)
    rescue StandardError => e
      warn "rubyclaw: could not raise the unreachable notice: #{e.class}: #{e.message}"
    end

    def announce_recovered
      n = notify_layer
      return unless n.signalled?(NOTICE_UNREACHABLE)

      n.signal(NOTICE_RECOVERED, "✅ RubyClaw is back in touch with Telegram. Carry on.")
      n.rearm(NOTICE_UNREACHABLE)
    rescue StandardError => e
      warn "rubyclaw: could not raise the recovery notice: #{e.class}: #{e.message}"
    end

    # Notify is loaded lazily: it requires this file, so a top-level require would be a
    # cycle. By the time the poll loop runs, requiring it here is a no-op.
    def notify_layer
      require_relative "notify"
      RubyClaw::Notify
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

      return handle_command(chat_id, text.strip, from: from) if text.start_with?("/")

      warn "rubyclaw: #{from}: #{text[0, 90]}"
      session = (@sessions[chat_id] ||= Harness.new(model: @model, base_url: @base_url,
                                                    api_key: @api_key, quiet: true))
      answer = with_typing(chat_id) { session.run(text).to_s }
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

    def handle_command(chat_id, cmd, from: nil)
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
      when "/approvals"
        list_approvals(chat_id)
      when "/approve", "/deny"
        decide_approval_from_chat(chat_id, cmd, from)
      when "/policy"
        policy_command(chat_id, cmd)
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
        send_message(chat_id, "/new  fresh conversation\n" \
                              "/approvals  what is waiting on you, with Approve/Deny buttons\n" \
                              "/approve <id>  grant one by text\n/deny <id>  refuse one by text\n" \
                              "/policy  show the autonomy policy; /policy auto|ask|block|human_only to set the default\n" \
                              "/prefer <text>  remember a preference\n/notes  what it has learned\n" \
                              "/tools  tool surface\n/stats  tool usage\n/model  resolved model + endpoint")
      else
        send_message(chat_id, "commands: /new /approvals /approve /deny /policy /prefer /notes /tools /stats /model")
      end
    end

    # ---- what is waiting on a person, and deciding it, from chat ----------
    #
    # The "I never saw it scroll past" fix: every pending approval as its own message,
    # carrying its own Approve/Deny buttons, so deciding one never means copying an id
    # out of a message that has already scrolled away. The text /approve and /deny below
    # are the fallback for a client that does not render inline buttons -- not a second
    # decision path: both call Work.decide_approval, the one path `claw work decide` uses.

    def list_approvals(chat_id)
      pending = Work.pending_approvals
      if pending.empty?
        send_message(chat_id, "No approvals pending.")
        return
      end
      pending.each { |a| send_approval(chat_id, a["id"], approval_line(a)) }
    end

    # What an approval is for, and how long it has waited, in a person's words.
    def approval_line(a)
      task = Work.find_task(a["task_id"])
      lines = ["🔔 Approval #{a['id']}",
               "for: #{a['action']}#{task && task['title'] ? " — #{task['title']}" : ''}",
               "task: #{a['task_id']}",
               "waiting: #{Work.age(a['requested'])}"]
      reason = (task && task["note"]) || a["note"]
      lines << "reason: #{reason}" if reason.to_s.strip != ""
      lines.join("\n")
    end

    def decide_approval_from_chat(chat_id, cmd, from)
      parts = cmd.split(" ", 2)
      intent = parts[0].to_s.sub(%r{\A/}, "")
      id = parts[1].to_s.strip
      if id.empty?
        send_message(chat_id, "usage: /#{intent} <approval_id> — list the ids with /approvals")
        return
      end

      decision = intent == "approve" ? "granted" : "denied"
      begin
        Work.decide_approval(id, decision, by: "telegram:#{from}")
        send_message(chat_id, decision == "granted" ? "✅ Approved #{id}." : "🚫 Denied #{id}.")
      rescue Error => e
        # A missing id, an unknown id and an already-decided approval each land here as
        # one clear line. Work does the read and the write under its store lock, so
        # nothing is half-applied when it refuses.
        send_message(chat_id, e.message)
      end
    end

    # ---- the policy, readable and changeable from chat --------------------
    #
    # The write goes to the instance layer (ROOT/instance/policy.yml), never to the
    # git-tracked policy.yml the project ships: a change made here must survive a
    # `git pull` instead of fighting it. Policy.set_default! writes the file and calls
    # Policy.reset!, so the new default is live on the very next check, no restart.

    def policy_command(chat_id, cmd)
      arg = cmd.split(" ", 2)[1].to_s.strip.downcase
      if arg.empty?
        send_message(chat_id, render_policy)
        return
      end

      begin
        file = Policy.set_default!(arg)
        send_message(chat_id, "✅ Policy default set to #{arg} in #{relative_path(file)}.\n\n#{render_policy}")
      rescue Error => e
        send_message(chat_id, e.message)
      end
    end

    # The effective policy as a person reads it: the default, which file it came from,
    # and the rules in force -- so the layering is visible rather than guessed at. The
    # rendering lives in Policy so `claw policy` and `/policy` cannot drift apart.
    def render_policy
      Policy.render
    end

    # ROOT-relative where it is under the root, absolute otherwise: a person sees
    # `instance/policy.yml`, not a tmpdir path.
    def relative_path(path)
      prefix = "#{ROOT}/"
      path.to_s.start_with?(prefix) ? path.to_s[prefix.length..] : path.to_s
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

    # A long turn must not look like a dead bot. Telegram's "typing…" state is good for
    # about five seconds, so one action at the start of a slow model turn vanishes long
    # before the answer does. Send it immediately, then refresh it on a side thread for as
    # long as the work runs; the thread is stopped the instant the block returns. A failed
    # action is swallowed by send_action, so a Telegram that will not take the indicator
    # cannot cost the answer either. No "on it!" message: the indicator is the whole
    # signal, and the voice lives in the reply.
    def with_typing(chat_id, interval: TYPING_REFRESH)
      send_action(chat_id, "typing")
      stop = Queue.new
      pulse = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          break unless stop.pop(timeout: interval).nil?   # nil = timed out, keep pulsing

          send_action(chat_id, "typing")
        end
      end
      yield
    ensure
      stop&.push(:stop)
      pulse&.join(2)
      pulse&.kill
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
