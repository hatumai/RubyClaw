# frozen_string_literal: true
# A fake Telegram Bot API, in-process. Same contract as scripts/tg_stub.rb, but
# usable inside a test without spawning anything.
#
#   tg = FakeTG.new(updates: [{ "update_id" => 1, "message" => { "chat" => {"id" => 42}, ... } }])
#   ENV["CLAW_TELEGRAM_API_BASE"] = tg.base
#   ...                                  # the adapter or the wizard talks to it
#   tg.sent                              # [{ chat_id:, text: }, ...]
#   tg.calls                             # method names it was asked for
module ClawTest
  class FakeTG
    MAX_HELD = 3600
    attr_reader :port, :sent, :calls, :edits, :answers, :get_updates_params

    def initialize(updates: [], user: { "id" => 1, "is_bot" => true, "first_name" => "stub",
                                        "username" => "stub_bot" },
                   hold: false, errors: {}, statuses: {}, delay: 0, fail_sends: 0,
                   fail_polls: 0, fail_polls_at: [])
      @queue = updates.dup
      @user = user
      @hold = hold                 # true: getUpdates always returns the same update
      @errors = errors             # method => description, for failure paths
      @statuses = statuses         # method => HTTP status to answer with (e.g. 401)
      @delay = delay               # seconds to sit on every reply: a *slow* API, for races that
                                   # only exist while a client is still connecting
      # The armv6 board's outbound TLS times out intermittently. This makes the FIRST
      # `fail_sends` sendMessage calls fail and the rest succeed, so a test can prove a
      # failed send is queued and then delivered rather than lost.
      @fail_sends = fail_sends
      # ...and the same for polls: the FIRST `fail_polls` getUpdates calls answer 503, as
      # a wedged link does, and the rest succeed. A test can then prove the poller rides
      # out a transient outage (and that the notice fires once, not once per failure).
      @fail_polls = fail_polls
      # ...or fail at chosen poll numbers (1-based), so a test can drive a SECOND outage
      # after a recovery and prove the notice re-fires for it: fail_polls_at: [1, 2, 4].
      @fail_polls_at = Array(fail_polls_at)
      @poll_seq = 0
      @sent = []
      @calls = []
      @edits = []                  # editMessageText / editMessageReplyMarkup payloads
      @answers = []                # answerCallbackQuery payloads
      @get_updates_params = []     # what the poller asked for (offset, allowed_updates)
      @mutex = Mutex.new
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def base = "http://127.0.0.1:#{@port}"

    def texts = @sent.map { |m| m[:text] }
    def markups = @sent.map { |m| m[:reply_markup] }
    def stop
      @server.close rescue nil
      @thread.kill
    end

    # A queued update from a private chat: what the wizard's discovery step looks for.
    def self.message(chat_id, text, username: "the operator", update_id: 1)
      { "update_id" => update_id,
        "message" => { "message_id" => update_id, "date" => Time.now.to_i,
                       "chat" => { "id" => chat_id, "type" => "private", "first_name" => "Alex" },
                       "from" => { "id" => chat_id, "is_bot" => false, "first_name" => "Alex",
                                   "username" => username },
                       "text" => text } }
    end

    # A queued inline-button tap: what Telegram delivers when a person presses Approve/Deny.
    def self.callback(chat_id, data, message_id: 7, text: "RubyClaw needs a person",
                      username: "the operator", update_id: 1)
      { "update_id" => update_id,
        "callback_query" => {
          "id" => "cbq-#{update_id}",
          "from" => { "id" => chat_id, "is_bot" => false, "first_name" => "Alex",
                      "username" => username },
          "message" => { "message_id" => message_id, "date" => Time.now.to_i,
                         "chat" => { "id" => chat_id, "type" => "private", "first_name" => "Alex" },
                         "from" => { "id" => 1, "is_bot" => true, "first_name" => "stub" },
                         "text" => text },
          "chat_instance" => "ci-1",
          "data" => data } }
    end

    private

    def serve
      loop do
        sock = @server.accept
        Thread.new(sock) { |s| handle(s) }
      rescue IOError, Errno::EBADF
        break
      rescue StandardError
        next
      end
    end

    def handle(sock)
      line = sock.gets.to_s
      headers = {}
      while (h = sock.gets) && h.strip != ""
        k, v = h.split(":", 2)
        headers[k.to_s.downcase.strip] = v.to_s.strip
      end
      len = headers["content-length"].to_i
      params = (JSON.parse(len.positive? ? sock.read(len) : "{}") rescue {})
      method = line.split(" ")[1].to_s.split("/").last
      @mutex.synchronize { @calls << method }
      sleep @delay if @delay.positive?
      status, result = method_result(method, params)
      payload = JSON.generate(result)
      reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
      sock.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    rescue StandardError
      nil
    ensure
      sock.close rescue nil
    end

    def method_result(method, params)
      if @errors.key?(method)
        status = @statuses[method] || 200
        return [status, { "ok" => false, "error_code" => (@statuses[method] || 400),
                          "description" => @errors[method] }]
      end
      case method
      when "getMe" then [200, { "ok" => true, "result" => @user }]
      when "getUpdates"
        # A chosen poll number that must fail -- lets a test script a second outage.
        seq = @mutex.synchronize { @poll_seq += 1 }
        if @fail_polls_at.include?(seq)
          return [503, { "ok" => false, "error_code" => 503,
                         "description" => "simulated transient outage" }]
        end
        # A transient outage: answer 503 until the budget runs out, then behave.
        failed = @mutex.synchronize { @fail_polls.positive? && (@fail_polls -= 1) }
        if failed
          return [503, { "ok" => false, "error_code" => 503,
                         "description" => "simulated transient outage" }]
        end
        out = @mutex.synchronize do
          @get_updates_params << params.dup
          if @hold
            @queue.dup
          else
            q = @queue.dup
            @queue.clear
            q
          end
        end
        [200, { "ok" => true, "result" => out }]
      when "sendMessage"
        fail_now = @mutex.synchronize do
          if @fail_sends.positive?
            @fail_sends -= 1
            true
          else
            @sent << { chat_id: params["chat_id"], text: params["text"].to_s,
                       reply_markup: params["reply_markup"] }
            false
          end
        end
        return [200, { "ok" => false, "description" => "simulated send failure" }] if fail_now

        [200, { "ok" => true, "result" => { "message_id" => @sent.size } }]
      when "editMessageText"
        @mutex.synchronize do
          @edits << { chat_id: params["chat_id"], message_id: params["message_id"],
                      text: params["text"].to_s, reply_markup: params["reply_markup"] }
        end
        [200, { "ok" => true, "result" => { "message_id" => params["message_id"] } }]
      when "editMessageReplyMarkup"
        @mutex.synchronize do
          @edits << { chat_id: params["chat_id"], message_id: params["message_id"],
                      reply_markup: params["reply_markup"], text: nil }
        end
        [200, { "ok" => true, "result" => { "message_id" => params["message_id"] } }]
      when "answerCallbackQuery"
        @mutex.synchronize do
          @answers << { callback_query_id: params["callback_query_id"], text: params["text"].to_s }
        end
        [200, { "ok" => true, "result" => true }]
      when "sendChatAction" then [200, { "ok" => true, "result" => true }]
      else [200, { "ok" => false, "description" => "unknown method #{method}" }]
      end
    end
  end
end
