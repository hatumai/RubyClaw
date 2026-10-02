# frozen_string_literal: true
# The smallest WebSocket client that can speak Chrome DevTools Protocol.
#
# Ruby ships no WebSocket client and RubyClaw ships no gems, so this is RFC 6455 by
# hand: an HTTP Upgrade handshake, then masked text frames over TCP or TLS. It handles
# what CDP actually uses -- text frames, fragmentation, ping/pong, close -- and nothing
# else (no extensions, no permessage-deflate, no server role).
require "socket"
require "openssl"
require "base64"
require "securerandom"
require "digest/sha1"
require "uri"

module RubyClaw
  class WS
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"    # RFC 6455 section 1.3
    MAX_FRAME = 64 * 1024 * 1024

    def initialize(url, timeout: 15)
      @uri = URI(url.to_s)
      raise Error, "websocket url must be ws:// or wss:// (got #{url})" unless %w[ws wss].include?(@uri.scheme)

      @buf = +""
      @closed = false
      @sock = connect(timeout)
      handshake(timeout)
    end

    def open? = !@closed && @sock && !@sock.closed?

    # Client frames must be masked; the server's must not be, and a server that masks is
    # a protocol error worth reporting rather than silently accepting.
    def send_text(str)
      raise Error, "websocket is closed" unless open?

      write_frame(0x1, str.to_s)
    end

    # Read one message. Returns a String (text or binary payload). Raises on close,
    # protocol error, or deadline.
    def recv(timeout: 30)
      deadline = timeout ? Time.now + timeout : nil
      data = +""
      loop do
        fin, opcode, payload = read_frame(deadline)
        case opcode
        when 0x0, 0x1, 0x2
          data << payload
          return data if fin
        when 0x9                                    # ping -> pong
          begin
            write_frame(0xA, payload)
          rescue IOError, SystemCallError => e
            @closed = true
            raise Error, "websocket closed while answering a ping (#{e.class})"
          end
        when 0xA then next                          # unsolicited pong: ignore
        when 0x8
          @closed = true
          code = payload.to_s.bytesize >= 2 ? payload.byteslice(0, 2).unpack1("n") : nil
          raise Error, "websocket closed by peer#{code ? " (code #{code})" : ''}"
        else
          raise Error, "unexpected websocket opcode #{opcode}"
        end
      end
    rescue Error, IOError, SystemCallError
      # A read that fails part-way through a frame leaves the stream desynchronised: the
      # bytes already taken from the socket are gone, so the next frame header would be
      # read from the middle of a payload. Close it and let the caller reconnect.
      @closed = true
      raise
    end

    def close
      return if @closed

      # A best-effort close handshake. Nothing depends on the peer answering, and a dead
      # socket must never raise on the way out.
      begin
        write_frame(0x8, [1000].pack("n"))
      rescue StandardError
        nil
      end
      @closed = true
      begin
        @sock&.close
      rescue StandardError
        nil
      end
    end

    private

    def connect(timeout)
      host = @uri.host || "127.0.0.1"
      port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
      sock = Socket.tcp(host, port, connect_timeout: timeout)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      if @uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        tls = OpenSSL::SSL::SSLSocket.new(sock, ctx)
        tls.hostname = host
        tls.sync_close = true
        tls.connect
        tls
      else
        sock
      end
    end

    # The handshake is where a wrong Sec-WebSocket-Accept hides: a proxy that answered
    # 101 with the wrong hash is not speaking WebSocket, and pretending otherwise would
    # fail later in a much more confusing place.
    def handshake(timeout)
      key = Base64.strict_encode64(SecureRandom.bytes(16))
      path = @uri.path.to_s.empty? ? "/" : @uri.path
      path += "?#{@uri.query}" if @uri.query
      host = @uri.host || "127.0.0.1"
      port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
      @sock.write("GET #{path} HTTP/1.1\r\n" \
                  "Host: #{host}:#{port}\r\n" \
                  "Upgrade: websocket\r\n" \
                  "Connection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: #{key}\r\n" \
                  "Sec-WebSocket-Version: 13\r\n\r\n")

      deadline = Time.now + timeout
      header = +""
      header << read_some(deadline, 4096) until header.include?("\r\n\r\n")
      lines = header.split("\r\n")
      status = lines.first.to_s.split(" ")[1].to_i
      raise Error, "websocket handshake failed: #{lines.first}" unless status == 101

      accept = lines.find { |l| l.downcase.start_with?("sec-websocket-accept:") }.to_s.split(":", 2)[1].to_s.strip
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      raise Error, "websocket handshake returned a bad accept hash" unless accept == expected

      # Anything the server sent after the headers belongs to the first frame.
      @buf = header.split("\r\n\r\n", 2)[1].to_s
      true
    end

    def write_frame(opcode, payload)
      payload = payload.to_s.dup.force_encoding(Encoding::BINARY)
      head = [0x80 | opcode].pack("C")
      len = payload.bytesize
      head << if len < 126
                [0x80 | len].pack("C")
              elsif len <= 0xFFFF
                [0x80 | 126, len].pack("Cn")
              else
                [0x80 | 127, len].pack("CQ>")
              end
      mask = SecureRandom.bytes(4)
      masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
      @sock.write(head + mask + masked)
    end

    def read_frame(deadline)
      head = read_exact(2, deadline)
      fin = (head.getbyte(0) & 0x80) != 0
      opcode = head.getbyte(0) & 0x0F
      masked = (head.getbyte(1) & 0x80) != 0
      len = head.getbyte(1) & 0x7F
      # if/elsif, not two ifs: a 16-bit extended length can itself be 127, and the second
      # `if` then read eight more bytes as a 64-bit length -- which is how a payload of
      # exactly 127 bytes consumed the start of its own body as a header.
      if len == 126
        len = read_exact(2, deadline).unpack1("n")
      elsif len == 127
        len = read_exact(8, deadline).unpack1("Q>")
      end
      if len > MAX_FRAME
        raise Error, "websocket frame too large (#{len} bytes; header #{head.unpack1('H*')})"
      end
      raise Error, "server sent a masked frame (protocol error)" if masked

      [fin, opcode, len.zero? ? "" : read_exact(len, deadline)]
    end

    def read_exact(n, deadline)
      @buf << read_some(deadline, 65_536) while @buf.bytesize < n
      chunk = @buf.byteslice(0, n)
      @buf = @buf.byteslice(n..).to_s
      chunk.force_encoding(Encoding::BINARY)
    end

    # Poll, and keep polling: returning nil for "nothing yet" used to be reported as a
    # timeout, which aborted a read in the middle of a frame -- and the bytes already
    # taken off the socket are gone, so the next header was read from inside a payload.
    # A frame that arrives in pieces, or a machine that stalls for 50ms, was enough.
    def read_some(deadline, max)
      loop do
        raise Error, "websocket read timed out" if deadline && Time.now >= deadline

        wait = deadline ? [[deadline - Time.now, 0.05].min, 0.01].max : nil
        next unless IO.select([@sock], nil, nil, wait)     # nothing yet: wait again

        data = @sock.read_nonblock(max, exception: false)
        next if data == :wait_readable
        raise Error, "websocket closed while reading" if data.nil?

        return data.force_encoding(Encoding::BINARY)
      end
    end
  end
end
