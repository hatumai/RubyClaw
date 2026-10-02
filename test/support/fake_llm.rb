# frozen_string_literal: true
# A scripted OpenAI-compatible endpoint. Stdlib sockets, one thread, no network.
#
# Serves /chat/completions and /models, records every request it receives (so a test
# can assert on the system prompt or the tool schema that was actually sent), and
# answers from a script:
#
#   llm = FakeLLM.new(script: [FakeLLM.says("hi"), FakeLLM.calls("sh", command: "echo hi")])
#   ...                       # first request gets "hi", second gets the tool call
#   llm.requests.last[:body]["tools"]        # what the harness offered
#
# With no script it repeats the last reply.
module ClawTest
  class FakeLLM
    attr_reader :port, :requests, :models

    def self.says(text, usage: nil)
      { "choices" => [{ "message" => { "role" => "assistant", "content" => text } }],
        "usage" => usage || { "prompt_tokens" => 10, "completion_tokens" => 2,
                              "prompt_cache_hit_tokens" => 4 } }
    end

    def self.calls(name, id: "call_1", **args)
      { "choices" => [{ "message" => {
        "role" => "assistant", "content" => nil,
        "tool_calls" => [{ "id" => id, "type" => "function",
                           "function" => { "name" => name, "arguments" => JSON.generate(args) } }]
      } }],
        "usage" => { "prompt_tokens" => 20, "completion_tokens" => 5, "prompt_cache_hit_tokens" => 0 } }
    end

    def initialize(script: [], models: %w[test-model-a test-model-b], status: 200, body: nil)
      @script = script
      @models = models
      @status = status
      @raw_body = body
      @requests = []
      @mutex = Mutex.new
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def base_url = "http://127.0.0.1:#{@port}/v1"

    def last_body = @requests.last&.dig(:body)
    def call_count = @requests.size
    def stop
      @server.close rescue nil
      @thread.kill
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
      raw = len.positive? ? sock.read(len) : nil
      path = line.split(" ")[1].to_s
      payload =
        if path.end_with?("/models")
          JSON.generate({ "object" => "list", "data" => @models.map { |m| { "id" => m } } })
        elsif @raw_body
          @raw_body
        else
          respond(raw)
        end
      code = @status == 200 ? "200 OK" : "#{@status} Error"
      sock.write("HTTP/1.1 #{code}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    rescue StandardError
      nil
    ensure
      sock.close rescue nil
    end

    def respond(raw)
      body = (JSON.parse(raw) rescue {})
      @mutex.synchronize do
        @requests << { path: "/chat/completions", body: body, headers: {} }
        reply = @script.empty? ? self.class.says("ok") :
                (@script.size > 1 ? @script.shift : @script.first)
        reply = reply.call(body) if reply.respond_to?(:call)
        JSON.generate(reply)
      end
    end
  end
end
