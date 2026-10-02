# frozen_string_literal: true
require_relative "test_helper"
require "socket"

# The WebSocket client is hand-written (Ruby ships none, RubyClaw ships no gems), so its
# framing gets tested against bytes rather than against Chrome -- a browser test can only
# tell you that something broke, not which byte.
#
# The case that matters most here is length 127: an extended 16-bit length can itself be
# 127, and reading the extended length with two separate `if`s instead of `if/elsif` made
# the parser consume eight bytes of the frame's own body as a 64-bit length. Chrome hit
# it on a payload of exactly 127 bytes, and it looked like this from the caller's side:
# `websocket frame too large (8872770094665184812 bytes)` -- the JSON being read as a
# number. Every boundary is tested now.
class WSTest < Minitest::Test
  require_relative "../lib/ws"

  LENGTHS = [0, 1, 125, 126, 127, 128, 129, 1_000, 65_535, 65_536, 70_000].freeze

  def mkframe(opcode, payload, fin: true, mask: false)
    payload = payload.dup.force_encoding(Encoding::BINARY)
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    len = payload.bytesize
    flag = mask ? 0x80 : 0
    head << if len < 126
              [flag | len].pack("C")
            elsif len <= 0xFFFF
              [flag | 126, len].pack("Cn")
            else
              [flag | 127, len].pack("CQ>")
            end
    head + payload
  end

  # A WS object wired to a socket we control, skipping the handshake: the framing is what
  # is under test, not the HTTP upgrade.
  def session(bytes)
    a, b = UNIXSocket.pair
    ws = RubyClaw::WS.allocate
    ws.instance_variable_set(:@sock, a)
    ws.instance_variable_set(:@buf, "".b)
    ws.instance_variable_set(:@closed, false)
    b.write(bytes)
    b.close
    ws
  end

  def test_every_length_class_round_trips
    LENGTHS.each do |n|
      payload = "z" * n
      got = session(mkframe(1, payload)).recv(timeout: 5)
      assert_equal payload.bytesize, got.bytesize, "payload of #{n} bytes must survive"
      assert_equal payload, got
    end
  end

  def test_a_payload_of_exactly_127_bytes_is_not_read_as_an_eight_byte_length
    body = '{"id":1,"result":{"type":"string","value":"' + ("x" * 127) + '"}}'
    body = body[0, 127]
    assert_equal 127, body.bytesize
    assert_equal body, session(mkframe(1, body)).recv(timeout: 5)
  end

  def test_a_fragmented_message_is_joined
    bytes = mkframe(1, "part1", fin: false) + mkframe(0, "part2")
    assert_equal "part1part2", session(bytes).recv(timeout: 5)
  end

  def test_two_frames_in_one_packet_are_returned_one_at_a_time
    ws = session(mkframe(1, "first") + mkframe(1, "second"))
    assert_equal "first", ws.recv(timeout: 5)
    assert_equal "second", ws.recv(timeout: 5)
  end

  def test_a_frame_split_across_writes_is_reassembled
    a, b = UNIXSocket.pair
    ws = RubyClaw::WS.allocate
    ws.instance_variable_set(:@sock, a)
    ws.instance_variable_set(:@buf, "".b)
    ws.instance_variable_set(:@closed, false)
    frame = mkframe(1, "split-across-packets")
    b.write(frame.byteslice(0, 5))
    b.flush
    sleep 0.15
    b.write(frame.byteslice(5..))
    b.close
    assert_equal "split-across-packets", ws.recv(timeout: 5)
  end

  def test_a_ping_is_answered_and_reading_continues
    a, b = UNIXSocket.pair
    ws = RubyClaw::WS.allocate
    ws.instance_variable_set(:@sock, a)
    ws.instance_variable_set(:@buf, "".b)
    ws.instance_variable_set(:@closed, false)
    b.write(mkframe(9, "ping") + mkframe(1, "after-ping"))
    assert_equal "after-ping", ws.recv(timeout: 5)
    # the pong comes back on the same socket the client wrote the request to
    pong = b.read_nonblock(64, exception: false)
    assert_equal [0xA], [pong.getbyte(0) & 0x0F], "a ping must be answered with a pong"
  end

  def test_a_masked_server_frame_is_a_protocol_error
    err = assert_raises(RubyClaw::Error) { session(mkframe(1, "bad", mask: true)).recv(timeout: 5) }
    assert_match(/masked/, err.message)
  end

  def test_a_close_frame_reports_the_code
    err = assert_raises(RubyClaw::Error) { session(mkframe(8, [1000].pack("n"))).recv(timeout: 5) }
    assert_match(/code 1000/, err.message)
  end

  def test_a_failed_read_closes_the_stream_rather_than_desynchronising
    ws = session(mkframe(1, "hi"))
    assert_equal "hi", ws.recv(timeout: 5)
    assert_raises(RubyClaw::Error) { ws.recv(timeout: 1) }   # nothing more is coming
    refute ws.open?, "a desynchronised stream must be closed, not reused"
  end
end
