# frozen_string_literal: true
require_relative "test_helper"

# The adapter, driven against a fake Bot API: default-deny, the command surface, and
# the chunking that keeps a long answer from being rejected by Telegram.
class TelegramTest < Minitest::Test
  include ClawTest

  # The adapter reads the Bot API base and the allowlist when it makes a request, not
  # when it is constructed, so the environment has to hold for the whole test -- a
  # construction-time override pointed the requests at whatever was in the shell.
  def setup
    @tg = FakeTG.new(updates: [])
    @saved = ENV.to_h
    ENV["CLAW_TELEGRAM_API_BASE"] = @tg.base
    ENV["CLAW_TELEGRAM_TOKEN"] = "stub"
    ENV["CLAW_TELEGRAM_ALLOWED"] = nil
  end

  def teardown
    ENV.replace(@saved)
    @tg.stop
    @llm&.stop
  end

  def adapter(allowed: nil, **opts)
    ENV["CLAW_TELEGRAM_ALLOWED"] = allowed
    RubyClaw::Telegram.new(**opts)
  end

  # Queue a message the way Telegram would deliver it. Tests that assert on the model
  # call count start from an empty queue, or the setup's own task spends a token.
  def queue(*texts, chat: 42)
    texts.each_with_index do |t, i|
      @tg.instance_variable_get(:@queue) << FakeTG.message(chat, t, update_id: rand(1_000_000) + i)
    end
  end

  def test_no_allowlist_refuses_every_chat_and_echoes_the_id
    queue("run date")
    a = adapter(allowed: nil)
    _, err = capture { a.run(max_polls: 1) }
    assert_equal 1, @tg.sent.size
    assert_match(/Not configured to talk to chat 42/, @tg.texts.first)
    assert_match(/telegram_allowed_chat_ids/, @tg.texts.first)
    assert_match(/refused/, err + "")
  end

  def test_no_allowlist_refuses_even_a_stranger
    queue("hello", chat: 999)
    adapter(allowed: "42").run(max_polls: 1)
    assert_match(/Not configured to talk to chat 999/, @tg.texts.first)
  end

  def test_an_allowed_chat_gets_a_task_run_through_the_model
    @llm = FakeLLM.new(script: [FakeLLM.calls("sh", command: "date -u +%H:%M:%SZ"),
                                FakeLLM.says("the time is 03:07:57Z")])
    a = adapter(allowed: "42", base_url: @llm.base_url, api_key: "x", model: "fake")
    queue("run date")
    capture { a.run(max_polls: 1) }
    assert_equal 2, @llm.call_count, "one tool call, one final answer"
    assert_match(/the time is 03:07:57Z/, @tg.texts.last)
    assert_includes @tg.calls, "sendChatAction"
  end

  def test_commands_answer_without_calling_the_model
    @llm = FakeLLM.new
    a = adapter(allowed: "42", base_url: @llm.base_url, api_key: "x")
    queue(*%w[/help /tools /model /stats /notes /unknowncmd])
    capture { a.run(max_polls: 1) }
    assert_equal 0, @llm.call_count, "commands must not spend tokens"
    assert(@tg.texts.any? { |t| t.include?("/prefer") }, "help should advertise /prefer")
    assert(@tg.texts.any? { |t| t.include?("read_file") }, "/tools should list the surface")
    assert(@tg.texts.any? { |t| t.include?("deepseek") || t.include?("endpoint") }, "/model should answer")
    assert(@tg.texts.any? { |t| t.include?("commands:") }, "an unknown command should hint")
  end

  # /prefer writes a note, so this one drives the real CLI inside a throwaway copy of
  # the tree instead of touching this machine's preferences.md.
  def test_prefer_records_a_preference_without_calling_the_model
    @llm = FakeLLM.new
    sb = Sandbox.new("tgprefer")
    env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_TELEGRAM_ALLOWED" => "42", "CLAW_BASE_URL" => @llm.base_url,
            "CLAW_API_KEY" => "x", "CLAW_MODEL" => "fake" }
    queue("/prefer be terse")
    out, st = sb.claw("telegram", "--once", env: env, timeout: 30)
    refute_equal 124, st.exitstatus, "`claw telegram --once` must return after one poll:\n#{out}"
    assert st.success?, out
    assert_equal 0, @llm.call_count, "a command must not spend tokens"
    assert_match(/be terse/, sb.read("preferences.md"))
    assert_match(/preference/, @tg.texts.last.to_s)
  ensure
    sb&.cleanup
  end

  def test_non_text_messages_are_refused_politely
    @tg.instance_variable_get(:@queue) <<
      { "update_id" => 5, "message" => { "chat" => { "id" => 42 }, "from" => { "first_name" => "C" },
                                         "photo" => [{ "file_id" => "x" }] } }
    a = adapter(allowed: "42")
    capture { a.run(max_polls: 1) }
    assert_match(/only read text/, @tg.texts.last)
  end

  def test_a_long_answer_is_split_losslessly
    a = adapter(allowed: "42")
    body = (1..400).map { |i| "line #{i} #{"y" * 20}" }.join("\n")
    parts = a.chunk(body)
    assert_operator parts.size, :>, 1
    parts.each { |p| assert_operator p.length, :<=, RubyClaw::Telegram::MAX_MSG }
    assert_equal body, parts.join
  end

  def test_chunk_handles_one_absurd_line
    a = adapter(allowed: "42")
    parts = a.chunk("z" * (RubyClaw::Telegram::MAX_MSG * 2 + 5))
    assert_equal 3, parts.size
    assert_equal RubyClaw::Telegram::MAX_MSG * 2 + 5, parts.join.length
  end

  def test_a_bad_token_surfaces_as_a_sentence
    bad = FakeTG.new(errors: { "getMe" => "Unauthorized" })
    ENV["CLAW_TELEGRAM_API_BASE"] = bad.base
    ENV["CLAW_TELEGRAM_ALLOWED"] = "42"
    err = assert_raises(RubyClaw::Error) { RubyClaw::Telegram.new.run(max_polls: 1) }
    assert_match(/Unauthorized/, err.message)
  ensure
    bad&.stop
  end

  def test_a_missing_token_explains_how_to_get_one
    ENV["CLAW_TELEGRAM_TOKEN"] = nil
    err = assert_raises(RubyClaw::Error) { RubyClaw::Telegram.new }
    assert_match(/BotFather/, err.message)
    assert_match(/\.env/, err.message)
  end

  # ---- inline approvals: the keyboard, sent -------------------------------------

  def test_the_approval_keyboard_is_two_buttons_well_inside_the_callback_limit
    id = "ap-#{'a' * 12}"
    kb = RubyClaw::Telegram.approval_keyboard(id)
    rows = kb["inline_keyboard"]
    assert_equal 1, rows.size, "one row"
    labels = rows.first.map { |b| b["text"] }
    assert_equal %w[Approve Deny], labels
    assert_equal "approve:#{id}", rows.first[0]["callback_data"]
    assert_equal "deny:#{id}", rows.first[1]["callback_data"]
    rows.first.each do |b|
      assert_operator b["callback_data"].bytesize, :<=, 64,
                      "callback_data must stay well inside Telegram's 64-byte limit"
    end
    assert_equal ["approve", id], RubyClaw::Telegram.parse_callback("approve:#{id}")
    assert_equal ["deny", id], RubyClaw::Telegram.parse_callback("deny:#{id}")
    assert_equal ["approve", "ap:a"], RubyClaw::Telegram.parse_callback("approve:ap:a"),
                 "only the first colon separates intent from id"
  end

  def test_callback_data_that_is_not_ours_is_refused
    ["", "approve", "approve:", "junk:x", "APPROVE:x", "nonsense", "-" * 65].each do |d|
      assert_nil RubyClaw::Telegram.parse_callback(d), "#{d.inspect} must not parse"
    end
  end

  def test_the_buttons_ride_the_last_chunk_and_the_message_still_reads
    a = adapter(allowed: "42")
    kb = RubyClaw::Telegram.approval_keyboard("ap-abcdef012345")
    body = (1..400).map { |i| "line #{i} #{"y" * 20}" }.join("\n")
    parts = a.chunk(body)
    assert_operator parts.size, :>, 1, "the fixture must actually be chunked"
    a.send_chunks(42, body, reply_markup: kb)
    assert_equal parts.size, @tg.sent.size
    @tg.sent[0..-2].each { |m| assert_nil m[:reply_markup], "only the last chunk carries the keyboard" }
    assert_equal kb, @tg.sent.last[:reply_markup]
    assert_equal body, @tg.sent.map { |m| m[:text] }.join, "the chunks still read as one message"
    assert_equal 42, @tg.sent.last[:chat_id]
  end

  def test_the_poller_asks_telegram_for_callback_queries
    queue("/help")
    adapter(allowed: "42").run(max_polls: 1)
    assert_includes @tg.get_updates_params.last["allowed_updates"], "callback_query",
                    "without this, a button tap would never be delivered"
  end

  # ---- inline approvals: the tap received ---------------------------------------
  #
  # These drive the real bot in a throwaway copy of the tree, because a decision writes
  # the work store. The fake Bot API lives in this process and the child reaches it over
  # loopback, so the allowlist, the poll loop and the store are all the real ones.

  def callback_env
    { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
      "CLAW_TELEGRAM_ALLOWED" => "42" }
  end

  # Create a task parked on an approval in the sandbox and return the approval id.
  def park_approval(sb)
    out, st = sb.ruby(<<~'RB')
      require "boot"; require "work"
      t = RubyClaw::Work.add_task(title: "held by policy")
      ap = RubyClaw::Work.request_approval(task_id: t["id"], action: "files.write")
      puts ap["id"]
    RB
    assert st.success?, out
    out.strip
  end

  def approval_in(sb, id)
    JSON.parse(sb.read("data", "approvals.json"))["approvals"].find { |a| a["id"] == id }
  end

  def tap(sb, update)
    @tg.instance_variable_get(:@queue) << update
    sb.claw("telegram", "--once", env: callback_env, timeout: 30)
  end

  def test_a_tap_approves_the_approval_and_spends_the_buttons
    sb = Sandbox.new("tgapprove")
    id = park_approval(sb)
    out, st = tap(sb, FakeTG.callback(42, "approve:#{id}", message_id: 7,
                                          text: "🔔 needs a person\napproval: #{id}", update_id: 21))
    assert st.success?, out
    assert_includes @tg.calls, "answerCallbackQuery", "the tap must not spin"
    assert_includes @tg.calls, "editMessageText"
    assert_equal "granted", approval_in(sb, id)["status"]
    assert_equal "telegram:the operator", approval_in(sb, id)["decided_by"],
                 "the decision went through Work.decide_approval, the CLI's path"
    edit = @tg.edits.last
    assert_match(/✅ Approved by the operator/, edit[:text])
    assert_equal({ "inline_keyboard" => [] }, edit[:reply_markup], "the buttons are spent")
    assert_equal 7, edit[:message_id]
    assert_equal 42, edit[:chat_id]
    assert_equal "Approved", @tg.answers.last[:text]
  ensure
    sb&.cleanup
  end

  def test_a_deny_tap_denies_and_spends_the_buttons
    sb = Sandbox.new("tgdeny")
    id = park_approval(sb)
    out, st = tap(sb, FakeTG.callback(42, "deny:#{id}", message_id: 8,
                                          text: "approval: #{id}", update_id: 22))
    assert st.success?, out
    assert_equal "denied", approval_in(sb, id)["status"]
    task = JSON.parse(sb.read("data", "work.json"))["tasks"].find { |t| t["id"] == approval_in(sb, id)["task_id"] }
    assert_equal "BLOCKED", task["state"], "a denial parks the task, the same as the CLI"
    assert_match(/🚫 Denied by the operator/, @tg.edits.last[:text])
    assert_equal "Denied", @tg.answers.last[:text]
  ensure
    sb&.cleanup
  end

  # The security bug this test exists to prevent: a callback names an approval id in
  # callback_data, so without an allowlist check anyone who learned an id could decide it.
  def test_a_callback_from_a_chat_not_on_the_allowlist_decides_nothing
    sb = Sandbox.new("tgcbdeny")
    id = park_approval(sb)
    out, st = tap(sb, FakeTG.callback(999, "approve:#{id}", message_id: 7, text: "x", update_id: 23))
    assert st.success?, out
    assert_includes @tg.calls, "answerCallbackQuery"
    refute_includes @tg.calls, "editMessageText", "an unlisted chat gets no edit"
    assert_equal "pending", approval_in(sb, id)["status"],
                 "a chat off the allowlist must not be able to decide an approval"
    assert_match(/Not configured/, @tg.answers.last[:text])
  ensure
    sb&.cleanup
  end

  def test_a_tap_on_an_unknown_approval_is_answered_not_a_crash
    sb = Sandbox.new("tgcbfake")
    out, st = tap(sb, FakeTG.callback(42, "approve:ap-doesnotexist", message_id: 7, text: "x", update_id: 24))
    assert st.success?, out
    assert_includes @tg.calls, "answerCallbackQuery"
    assert_match(/no approval/, @tg.answers.last[:text])
    refute_match(/update failed: .*no approval/, out, "the callback error is contained, not a crash")
  ensure
    sb&.cleanup
  end

  def test_a_second_tap_on_a_decided_approval_is_handled_and_does_not_flip_it
    sb = Sandbox.new("tgcbsecond")
    id = park_approval(sb)
    d, dst = sb.ruby(<<~RB)
      require "boot"; require "work"
      RubyClaw::Work.decide_approval("#{id}", "granted", by: "cli")
    RB
    assert dst.success?, d
    out, st = tap(sb, FakeTG.callback(42, "approve:#{id}", message_id: 7, text: "x", update_id: 25))
    assert st.success?, out
    assert_match(/already granted/, @tg.answers.last[:text])
    assert_equal "granted", approval_in(sb, id)["status"], "the first decision stands"
    assert_equal "cli", approval_in(sb, id)["decided_by"]
    assert_includes @tg.calls, "editMessageText"
  ensure
    sb&.cleanup
  end

  def test_callback_data_that_does_not_parse_is_ignored_without_deciding
    sb = Sandbox.new("tgcbbad")
    id = park_approval(sb)
    out, st = tap(sb, FakeTG.callback(42, "not-a-callback", message_id: 7, text: "x", update_id: 26))
    assert st.success?, out
    assert_match(/Unrecognised/, @tg.answers.last[:text])
    refute_includes @tg.calls, "editMessageText"
    assert_equal "pending", approval_in(sb, id)["status"]
  ensure
    sb&.cleanup
  end
end
