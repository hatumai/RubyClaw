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

  # ---- surviving a bad network, and saying so ------------------------------
  #
  # Outbound TLS to api.telegram.org times out intermittently on the armv6 board. The
  # reported bug: six consecutive failed polls raised and killed the poller, so the bot
  # went silent for good. These drive the real loop in a sandbox child (its
  # notifications land in the sandbox's own data/) against a FakeTG in this process.

  # Drive RubyClaw::Telegram#run in a sandbox child, pointed at @tg, and return
  # [output, status]. max_failures is small so a notice is reached without waiting out
  # the full backoff.
  def drive_poller(sb, max_polls: 5, max_failures: 1)
    code = <<~RB
      require "telegram"
      tg = RubyClaw::Telegram.new(allowed: ["42"])
      puts "POLLS=\#{tg.run(max_polls: #{max_polls})}"
    RB
    env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_TELEGRAM_ALLOWED" => "42", "CLAW_TG_MAX_FAILURES" => max_failures.to_s }
    sb.ruby(code, env: env)
  end

  def test_a_transient_poll_failure_does_not_stop_the_poller
    @tg.stop
    @tg = FakeTG.new(updates: [FakeTG.message(42, "/help")], fail_polls: 2)
    sb = Sandbox.new("tgsurvive")
    out, st = drive_poller(sb, max_polls: 5, max_failures: 1)
    assert st.success?, out
    assert_match(/POLLS=5/, out, "the loop must run every poll, not die at the failure limit:\n#{out}")
    refute_match(/stopping —/, out, "a transient outage must not stop the poller")
    assert(@tg.texts.any? { |t| t.include?("/prefer") },
           "a message queued behind the outage was finally answered:\n#{@tg.texts.inspect}")
  ensure
    sb&.cleanup
  end

  # The one fatal poll failure: a revoked token cannot start working by being retried,
  # so the loop stops, says why in one line, and does not poll on.
  def test_a_bad_token_during_polling_stops_the_loop_and_says_why
    @tg.stop
    @tg = FakeTG.new(errors: { "getUpdates" => "Unauthorized" }, statuses: { "getUpdates" => 401 })
    ENV["CLAW_TELEGRAM_API_BASE"] = @tg.base
    a = adapter(allowed: "42")
    out, err = capture { a.run(max_polls: 3) }
    assert_match(/stopping — Telegram rejected the credentials/, err, "it must say why it stopped")
    assert_match(/401|Unauthorized/, err)
    assert_match(/CLAW_TELEGRAM_TOKEN/, err, "and name the fix")
    assert_equal 1, @tg.calls.count("getUpdates"), "a bad token stops the loop instead of hammering it"
    refute_match(/poll failed/, err, "a 401 is not a transient poll failure")
  ensure
    nil
  end

  def test_the_unreachable_notice_fires_once_not_once_per_failed_poll
    @tg.stop
    @tg = FakeTG.new(updates: [FakeTG.message(42, "/help")], fail_polls: 2)
    sb = Sandbox.new("tgonce")
    out, st = drive_poller(sb, max_polls: 5, max_failures: 1)
    assert st.success?, out
    notices = @tg.texts.count { |t| t.include?("can't reach Telegram") }
    assert_equal 1, notices, "two failed polls past the threshold but one notice:\n#{@tg.texts.inspect}"
  ensure
    sb&.cleanup
  end

  def test_the_recovery_notice_fires_when_polls_resume
    @tg.stop
    @tg = FakeTG.new(updates: [FakeTG.message(42, "/help")], fail_polls: 1)
    sb = Sandbox.new("tgrecover")
    out, st = drive_poller(sb, max_polls: 4, max_failures: 1)
    assert st.success?, out
    assert_equal 1, @tg.texts.count { |t| t.include?("can't reach Telegram") }, out
    assert_equal 1, @tg.texts.count { |t| t.include?("back in touch") },
                 "the recovery is announced exactly once:\n#{@tg.texts.inspect}\n#{out}"
  ensure
    sb&.cleanup
  end

  # The gap the first two tests left: re-notification after a SECOND outage. The loop
  # re-arms the opposite key on each transition, so a later outage is heard again instead
  # of being deduped into silence forever. The script is fail, fail, ok, fail, ok: two
  # failed polls for the first outage, a recovery, then a second outage, then a recovery.
  # Each notice must fire exactly once per transition -- one unreachable and one recovery
  # per outage-and-recovery pair -- even though the first outage spans two failed polls.
  def test_a_second_outage_is_announced_again_once_per_transition
    @tg.stop
    @tg = FakeTG.new(fail_polls_at: [1, 2, 4])
    sb = Sandbox.new("tgream")
    out, st = drive_poller(sb, max_polls: 5, max_failures: 1)
    assert st.success?, out
    assert_match(/POLLS=5/, out, "the loop rode out both outages and ran every poll:\n#{out}")
    unreachable = @tg.texts.count { |t| t.include?("can't reach Telegram") }
    recovered = @tg.texts.count { |t| t.include?("back in touch") }
    assert_equal 2, unreachable,
                 "one notice per outage, and the second outage was announced again:\n#{@tg.texts.inspect}\n#{out}"
    assert_equal 2, recovered,
                 "one recovery notice per recovery, and the second recovery was announced:\n#{@tg.texts.inspect}\n#{out}"
  ensure
    sb&.cleanup
  end

  # ---- /approvals, /approve, /deny: deciding from chat ---------------------
  #
  # The text surface for the approval store. /approvals is the "I never saw it scroll
  # past" fix: one message per pending approval, each carrying its own buttons. /approve
  # and /deny are the fallback for a client that does not render buttons, resolving
  # through Work.decide_approval -- the one path the buttons and `claw work decide` use.

  # Queue a command and drive the real bot once; the command answers from @tg.
  def run_command(sb, text, chat: 42, env: {})
    queue(text, chat: chat)
    sb.claw("telegram", "--once", env: callback_env.merge(env), timeout: 30)
  end

  def test_approvals_lists_each_pending_one_with_its_own_buttons
    sb = Sandbox.new("tglistapps")
    id1 = park_approval(sb)
    id2 = park_approval(sb)
    out, st = run_command(sb, "/approvals")
    assert st.success?, out

    bodies = @tg.texts.select { |t| t.include?("🔔 Approval") }
    assert_equal 2, bodies.size, "one message per pending approval:\n#{@tg.texts.inspect}"
    [id1, id2].each do |id|
      body = bodies.find { |t| t.include?(id) }
      refute_nil body, "approval #{id} must be listed"
      assert_match(/for: files\.write/, body, "what it is for")
      assert_match(/waiting: /, body, "how long it has waited")
    end

    callbacks = @tg.sent.flat_map do |m|
      kb = m[:reply_markup]
      kb ? kb["inline_keyboard"].flatten.map { |b| b["callback_data"] } : []
    end
    [id1, id2].each do |id|
      assert_includes callbacks, "approve:#{id}", "each entry carries its own Approve button"
      assert_includes callbacks, "deny:#{id}", "each entry carries its own Deny button"
    end
  ensure
    sb&.cleanup
  end

  def test_approvals_with_nothing_pending_says_so_in_one_line
    sb = Sandbox.new("tgnoapps")
    out, st = run_command(sb, "/approvals")
    assert st.success?, out
    assert_equal 1, @tg.sent.size, "one line, not a message per imagined approval:\n#{@tg.texts.inspect}"
    assert_match(/No approvals pending/, @tg.texts.first)
    assert_nil @tg.sent.first[:reply_markup]
  ensure
    sb&.cleanup
  end

  def test_approve_by_text_grants_through_the_same_path_as_the_buttons
    sb = Sandbox.new("tgapprovetext")
    id = park_approval(sb)
    out, st = run_command(sb, "/approve #{id}")
    assert st.success?, out
    a = approval_in(sb, id)
    assert_equal "granted", a["status"]
    assert_equal "telegram:the operator", a["decided_by"],
                 "attributed to the sender, through Work.decide_approval"
    assert_match(/✅ Approved #{id}/, @tg.texts.last)
    task = JSON.parse(sb.read("data", "work.json"))["tasks"].find { |t| t["id"] == a["task_id"] }
    assert_equal "WORKING", task["state"], "a grant hands the task back, the same as the CLI"
  ensure
    sb&.cleanup
  end

  def test_deny_by_text_denies_and_parks_the_task
    sb = Sandbox.new("tgdenytext")
    id = park_approval(sb)
    out, st = run_command(sb, "/deny #{id}")
    assert st.success?, out
    a = approval_in(sb, id)
    assert_equal "denied", a["status"]
    assert_equal "telegram:the operator", a["decided_by"]
    assert_match(/🚫 Denied #{id}/, @tg.texts.last)
    task = JSON.parse(sb.read("data", "work.json"))["tasks"].find { |t| t["id"] == a["task_id"] }
    assert_equal "BLOCKED", task["state"]
  ensure
    sb&.cleanup
  end

  def test_approve_without_an_id_says_how_to_find_one
    sb = Sandbox.new("tgappnoid")
    out, st = run_command(sb, "/approve")
    assert st.success?, out
    assert_match(%r{usage: /approve <approval_id>}, @tg.texts.last)
    assert_match(%r{/approvals}, @tg.texts.last)
  ensure
    sb&.cleanup
  end

  def test_approving_an_unknown_id_is_one_line_not_a_crash
    sb = Sandbox.new("tgappunknown")
    out, st = run_command(sb, "/approve ap-doesnotexist")
    assert st.success?, out
    assert_match(/no approval ap-doesnotexist/, @tg.texts.last)
    refute_match(/update failed: .*no approval/, out, "an unknown id is answered, not a crash")
  ensure
    sb&.cleanup
  end

  def test_approving_an_already_decided_one_does_not_flip_it
    sb = Sandbox.new("tgappdecided")
    id = park_approval(sb)
    d, dst = sb.ruby(<<~RB)
      require "boot"; require "work"
      RubyClaw::Work.decide_approval("#{id}", "granted", by: "cli")
    RB
    assert dst.success?, d
    out, st = run_command(sb, "/approve #{id}")
    assert st.success?, out
    assert_match(/already granted/, @tg.texts.last)
    assert_equal "granted", approval_in(sb, id)["status"], "the first decision stands"
    assert_equal "cli", approval_in(sb, id)["decided_by"]
  ensure
    sb&.cleanup
  end

  # ---- /policy: reading and setting the autonomy policy from chat ----------

  def test_policy_shows_the_effective_default_source_and_rules
    sb = Sandbox.new("tgpolicyshow")
    out, st = run_command(sb, "/policy", env: { "CLAW_POLICY" => nil })
    assert st.success?, out
    text = @tg.texts.last
    assert_match(/default: ask/, text)
    assert_match(%r{source:  policy\.yml}, text)
    assert_match(/project policy\.yml/, text, "it names the file the policy came from")
    assert_match(/files\.read -> auto/, text, "the rules in force are listed")
    assert_match(/work\.decide -> human_only/, text)
    refute sb.exist?("instance", "policy.yml"), "reading the policy writes nothing"
  ensure
    sb&.cleanup
  end

  def test_policy_sets_the_default_in_the_instance_layer_and_leaves_the_tracked_file_alone
    sb = Sandbox.new("tgpolicyset")
    tracked_before = sb.read("policy.yml")
    out, st = run_command(sb, "/policy auto", env: { "CLAW_POLICY" => nil })
    assert st.success?, out
    assert sb.exist?("instance", "policy.yml"), "the instance layer is created"
    assert_equal tracked_before, sb.read("policy.yml"),
                 "the git-tracked policy.yml must never be written by a chat command"
    inst = sb.read("instance", "policy.yml")
    assert_match(/^default: auto$/, inst)
    assert_match(/files\.read/, inst, "the rules in force are carried over, not dropped")
    assert_match(/work\.decide/, inst)
    assert_match(%r{Policy default set to auto in instance/policy\.yml}, @tg.texts.last)
    assert_match(%r{source:  instance/policy\.yml}, @tg.texts.last)
    assert_match(/instance layer/, @tg.texts.last, "the reply shows which layer now wins")

    # A fresh process reads the instance layer, and the shipped rules still apply.
    eff, st2 = sb.ruby(<<~'RB', env: { "CLAW_POLICY" => nil })
      require "boot"; require "policy"
      P = RubyClaw::Policy
      puts "path=#{P.path.sub(Dir.pwd + '/', '')} default=#{P.decide('anything')['policy']} " \
           "shell=#{P.decide('shell.run')['policy']}"
    RB
    assert st2.success?, eff
    assert_match(%r{path=instance/policy\.yml default=auto shell=ask}, eff,
                 "the instance default is in force while the shipped rules still apply")
  ensure
    sb&.cleanup
  end

  def test_policy_refuses_an_unknown_name_and_lists_the_four
    sb = Sandbox.new("tgbadpolicy")
    tracked_before = sb.read("policy.yml")
    out, st = run_command(sb, "/policy whenever", env: { "CLAW_POLICY" => nil })
    assert st.success?, out
    assert_match(/unknown policy "whenever"/, @tg.texts.last)
    assert_match(/auto \| ask \| block \| human_only/, @tg.texts.last)
    refute sb.exist?("instance", "policy.yml"), "a refused name writes nothing"
    assert_equal tracked_before, sb.read("policy.yml"), "and the tracked file is untouched"
  ensure
    sb&.cleanup
  end

  # reset! is what makes the change live in the SAME process, with no restart. Driving
  # handle_command and then re-checking the policy in one child proves it: without
  # reset! the memoised config from before the write would still answer.
  def test_setting_the_policy_takes_effect_without_a_restart
    sb = Sandbox.new("tgpolicyreset")
    code = <<~'RB'
      require "boot"; require "telegram"; require "policy"
      a = RubyClaw::Telegram.new(allowed: ["42"])
      puts "before=#{RubyClaw::Policy.decide('anything')['policy']}"
      a.handle_command(42, "/policy block")
      puts "after=#{RubyClaw::Policy.decide('anything')['policy']}"
      puts "path=#{RubyClaw::Policy.path.sub(Dir.pwd + '/', '')}"
    RB
    env = { "CLAW_TELEGRAM_API_BASE" => @tg.base, "CLAW_TELEGRAM_TOKEN" => "stub",
            "CLAW_TELEGRAM_ALLOWED" => "42", "CLAW_POLICY" => nil }
    out, st = sb.ruby(code, env: env)
    assert st.success?, out
    assert_match(/before=ask/, out, "the shipped default before the command")
    assert_match(/after=block/, out, "the instance default, live in the same process -- no restart")
    assert_match(%r{path=instance/policy\.yml}, out)
  ensure
    sb&.cleanup
  end

  # ---- the allowlist gates every command (the security half) ---------------

  # A chat that is not allowlisted must be refused before any of these runs, and must
  # change nothing: no decision, no store write, no policy file. This is the same rule
  # handle_message enforces for a plain message and handle_callback for a button.
  def test_a_command_from_a_chat_not_on_the_allowlist_changes_nothing
    sb = Sandbox.new("tgcmddeny")
    id = park_approval(sb)

    out, st = run_command(sb, "/approve #{id}", chat: 999)
    assert st.success?, out
    assert_match(/Not configured to talk to chat 999/, @tg.texts.last)
    assert_equal "pending", approval_in(sb, id)["status"],
                 "a chat off the allowlist must not be able to decide an approval"

    out2, st2 = run_command(sb, "/deny #{id}", chat: 999)
    assert st2.success?, out2
    assert_equal "pending", approval_in(sb, id)["status"], "and cannot deny it either"

    out3, st3 = run_command(sb, "/policy auto", chat: 999)
    assert st3.success?, out3
    refute sb.exist?("instance", "policy.yml"), "an unlisted chat must not write the policy layer"
    refute_match(/Policy default set/, @tg.texts.last)

    out4, st4 = run_command(sb, "/approvals", chat: 999)
    assert st4.success?, out4
    assert_match(/Not configured to talk to chat 999/, @tg.texts.last)
    refute_match(/Approval ap-/, @tg.texts.last, "an unlisted chat is not even shown what is pending")
  ensure
    sb&.cleanup
  end

  # ---- never look dead while it works --------------------------------------

  # A long model turn used to send nothing until the answer, which reads as a bot that
  # ignored you. The typing indicator goes out immediately and precedes the answer; and
  # it is the indicator, not a chatty "on it!" message.
  def test_a_typing_action_is_sent_before_the_answer
    @llm = FakeLLM.new(script: [FakeLLM.says("done")])
    a = adapter(allowed: "42", base_url: @llm.base_url, api_key: "x", model: "fake")
    queue("do the thing")
    capture { a.run(max_polls: 1) }
    assert_includes @tg.calls, "sendChatAction"
    action_at = @tg.calls.index("sendChatAction")
    answer_at = @tg.calls.index("sendMessage")
    refute_nil answer_at, "the answer must be sent"
    assert_operator action_at, :<, answer_at, "the typing indicator must precede the answer"
    assert_equal ["done"], @tg.texts, "no 'on it!' message — only the answer carries the voice"
  end

  # If Telegram will not take the indicator, the work and the answer must not be lost.
  def test_a_failed_typing_action_does_not_lose_the_answer
    @tg.stop
    @tg = FakeTG.new(errors: { "sendChatAction" => "typing not allowed" })
    ENV["CLAW_TELEGRAM_API_BASE"] = @tg.base
    @llm = FakeLLM.new(script: [FakeLLM.says("the answer, delivered anyway")])
    a = adapter(allowed: "42", base_url: @llm.base_url, api_key: "x", model: "fake")
    queue("say something")
    capture { a.run(max_polls: 1) }
    assert_includes @tg.calls, "sendChatAction", "the indicator was attempted"
    assert_match(/the answer, delivered anyway/, @tg.texts.last,
                 "a rejected typing action must not cost the answer")
  end
end
