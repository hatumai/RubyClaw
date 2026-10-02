# frozen_string_literal: true
# A fake Telegram Bot API, so the adapter can be tested end to end without a bot
# token, a real chat, or a network. Stdlib sockets only.
#
#   ruby scripts/tg_stub.rb <port> <updates.json> <out.jsonl>
#
# Serves getMe, getUpdates (hands back each queued update once, then empty),
# sendMessage and sendChatAction. Everything the bot sends is appended to
# out.jsonl so the test can assert on the actual replies.
require "socket"
require "json"

PORT    = (ARGV[0] || 8899).to_i
UPDATES = ARGV[1] || "scripts/tg_updates.json"
OUT     = ARGV[2] || "/tmp/tg_out.jsonl"

queue = JSON.parse(File.read(UPDATES))
File.write(OUT, "")

server = TCPServer.new("127.0.0.1", PORT)
warn "tg_stub: listening on 127.0.0.1:#{PORT}, #{queue.size} queued update(s), writing to #{OUT}"

loop do
  sock = server.accept
  begin
    req_line = sock.gets.to_s
    headers = {}
    while (line = sock.gets) && line.strip != ""
      k, v = line.split(":", 2)
      headers[k.to_s.downcase.strip] = v.to_s.strip
    end
    len = headers["content-length"].to_i
    body = len.positive? ? sock.read(len) : nil
    path = req_line.split(" ")[1].to_s
    method = path.split("/").last.to_s
    params = (JSON.parse(body) rescue {}) || {}

    result =
      case method
      when "getMe"
        { "id" => 1, "is_bot" => true, "first_name" => "stub", "username" => "stub_bot" }
      when "getUpdates"
        out = queue.dup
        queue.clear
        out
      when "sendMessage"
        File.open(OUT, "a") { |f| f.puts JSON.generate(chat_id: params["chat_id"], text: params["text"],
                                                       reply_markup: params["reply_markup"]) }
        warn "tg_stub: -> chat #{params['chat_id']}: #{params['text'].to_s[0, 110].inspect}" \
             "#{params['reply_markup'] ? ' [buttons]' : ''}"
        { "message_id" => rand(1000) }
      when "editMessageText", "editMessageReplyMarkup"
        File.open(OUT, "a") { |f| f.puts JSON.generate(method: method, chat_id: params["chat_id"],
                                                       message_id: params["message_id"],
                                                       text: params["text"],
                                                       reply_markup: params["reply_markup"]) }
        warn "tg_stub: #{method} message #{params['message_id']}"
        { "message_id" => params["message_id"] }
      when "answerCallbackQuery"
        warn "tg_stub: answerCallbackQuery #{params['callback_query_id']}: #{params['text'].to_s[0, 80]}"
        true
      when "sendChatAction" then true
      else
        warn "tg_stub: unknown method #{method}"
        nil
      end

    payload = JSON.generate(ok: true, result: result)
    sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  rescue StandardError => e
    warn "tg_stub: error #{e.class}: #{e.message}"
  ensure
    sock.close rescue nil
  end
end
