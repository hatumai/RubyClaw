# frozen_string_literal: true
# The interactive surface. `claw` with no arguments drops into the local prompt;
# `claw up` runs the Telegram bot in a background thread and keeps the local prompt
# in the foreground, so the same box is reachable from your phone and from a shell
# without two processes fighting over the repo.
require_relative "harness"
require_relative "claim"
require_relative "telegram"
require_relative "heartbeat"

module RubyClaw
  class Chat
    HELP = <<~HELP
      /prefer X  record a standing preference (tone, format, a rule) — it survives restarts
      /notes     show preferences.md, memory.md and the skills it wrote
      /new       forget the conversation and start fresh
      /tools     the tool surface ([core] builtin, [self] written by the harness)
      /stats     per-tool usage: calls, errors, last used
      /model     resolved model, endpoint, key source
      /evo       what the harness has grown, including rejected attempts
      /rollback  revert the last self-commit
      /help      this
      /quit      leave (Ctrl-D works too)
      Anything else is a task: it can call tools, and it can write itself new ones.
    HELP

    def initialize(model: nil, base_url: nil, api_key: nil)
      @model = model
      @base_url = base_url
      @api_key = api_key
      @session = nil
    end

    def session
      @session ||= Harness.new(model: @model, base_url: @base_url, api_key: @api_key)
    end

    def banner(telegram: nil)
      say "RubyClaw — #{RubyClaw.tools.size} tools, model #{@model || RubyClaw.model_name}"
      say "endpoint #{@base_url || RubyClaw.base_url}  (key: #{RubyClaw.key_source})"
      say telegram ? "Telegram: @#{telegram} is live — this prompt still works. /help for commands." :
                     "/help for commands, /quit to leave."
    end

    # Telegram in a thread, local prompt in the foreground. One process, one repo,
    # one conversation per chat.
    # Recurring jobs run while this process is up, so `claw up` is a complete answer for
    # someone who never logs out. It is not the *only* answer: cron runs `claw schedd
    # --once` too, which is what covers a reboot, and the two share the store and the lock
    # rather than fighting over it.
    def start_scheduler
      # Started even with an empty store: `return if count.zero?` meant a job added later --
      # by the model, from this prompt -- was never picked up in-process, so it waited for a
      # cron tick that may not be installed yet.
      count = Schedule.load.count { |j| j["enabled"] != false }
      say "scheduler: #{count} job(s) loaded from data/schedule.json" if count.positive?
      Thread.new do
        Thread.current.report_on_exception = false
        Schedule.daemon(poll: 30, on_tick: proc { |r|
          say "scheduled #{r['name']}: #{r['ok'] ? 'ok' : 'FAILED'} in #{r['seconds']}s"
        }, on_pass: proc { Heartbeat.pass })
      rescue StandardError => e
        warn "rubyclaw: scheduler stopped: #{e.class}: #{e.message}"
      end
    end

    # The tree's ownership lives in RubyClaw::Claim, which the entry point takes *before* the
    # slow boot. These are the names the rest of the harness already uses.
    def self.serve_pid = Claim.pid
    def self.serve_running? = Claim.held_by_other?
    def self.claim_served! = Claim.claim!
    def self.release_served! = Claim.release!

    # telegram_only: run the bot and nothing else -- no prompt, no stdin. That is the shape a
    # service needs: under a supervisor stdin is /dev/null, and the prompt loop exits on the
    # first EOF, which would take the bot thread down with it seconds after start.
    def serve(telegram_only: false, if_not_running: false)
      # Signals first, before any slow work here. The entry point installs a stop handler even
      # earlier (before it loads this tree, which is 7-8 s on the armv6 board) so that a TERM
      # during boot is a clean stop, not a signalled exit a supervisor reads as a crash; this
      # re-arms them with the graceful handler that parks the bot.
      @stopping = false
      %w[INT TERM].each { |sig| Signal.trap(sig) { @stopping = true } } if telegram_only

      # The keeper path next: called every few minutes from cron, it must never start a second
      # poller.
      if telegram_only
        if if_not_running && Chat.serve_running?
          say Claim.running_note
          return 0
        end
        # Either this process owns the tree from here, or another one does and this run is a
        # no-op. The entry point normally claimed it before booting, and claim! is idempotent,
        # so this is that same claim rather than a second one.
        unless Chat.claim_served!
          say Claim.running_note
          return 0
        end
      end

      # Before Telegram, deliberately: the scheduler does not depend on a bot token, and
      # starting it after the Telegram setup meant a machine with no bot silently ran no
      # scheduled work at all.
      start_scheduler
      tg = nil
      begin
        tg = Telegram.new(model: @model, base_url: @base_url, api_key: @api_key)
        me = tg.api("getMe")
      rescue StandardError => e
        # No token, a bad token, or no network: none of those should stop you
        # chatting locally, and none of them should print a backtrace.
        if telegram_only
          # A stop that arrived while connecting is still a clean stop.
          return 0 if @stopping

          # Otherwise: the bot *was* the job. A service that stays up with no bot is worse than
          # one that stops and says why: say why, and exit non-zero so a supervisor reports it.
          warn "rubyclaw: Telegram is not available (#{e.message.to_s.split("\n").first})"
          return 1
        end
        say "Telegram is not available (#{e.message.to_s.split("\n").first})"
        say "`claw setup` adds a bot; carrying on with the local prompt."
        return repl
      end
      bot = tg
      bot_thread = Thread.new do
        Thread.current.report_on_exception = false
        bot.run
      rescue StandardError => e
        warn "rubyclaw: telegram stopped: #{e.class}: #{e.message}"
      end
      banner(telegram: me["username"])
      return park(bot_thread) if telegram_only

      loop_repl
    end

    # Stay alive for the bot thread with no stdin to read, and stop the way a service should.
    # The trap handler only sets a flag: doing real work inside a signal handler is how you get a
    # deadlock at shutdown, and the flag is picked up within a second.
    def park(bot = nil)
      # The handlers were installed at the top of serve; this only waits for one of them to fire.
      loop do
        return 0 if @stopping

        # A bot thread that died must not leave this process parked. The keeper's "already running"
        # check would go on saying yes and the chat would be silently dead -- measured on the test
        # bed, where a TLS handshake starved by load timed out every poll, the bot gave up after
        # six, and the service sat there looking healthy with no bot at all. Exit non-zero instead,
        # so the keeper's next run brings it back and a supervisor sees a real failure.
        if bot && !bot.alive?
          warn "rubyclaw: the bot stopped; exiting so the keeper starts it again"
          return 1
        end
        sleep 1
      end
    end

    def repl
      banner
      loop_repl
    end

    def loop_repl
      loop do
        print "\n> "
        $stdout.flush
        line = $stdin.gets
        break if line.nil?
        line = line.strip
        next if line.empty?
        case dispatch(line)
        when :quit then break
        when :handled then next
        else
          begin
            say "\n#{session.run(line)}\n#{session.usage_line}"
          rescue Interrupt
            say "\n(interrupted)"
          rescue StandardError => e
            say "\n! #{e.class}: #{e.message}"
          end
        end
      end
      say "bye."
    end

    # :quit, :handled for anything this class deals with itself, nil for a task.
    def dispatch(line)
      return nil unless line.start_with?("/") || line.start_with?(":")
      # `:prefer` is accepted as well as `/prefer`, but the colon translation used to
      # apply to the whole line: "/prefer keep HH:MM in the notes" stored
      # "keep HH/MM in the notes".
      cmd, *rest = line.split(" ")
      cmd = "/#{cmd[1..]}" if cmd.start_with?(":")
      case cmd
      when "/quit", "/exit" then :quit
      when "/new", "/start"
        @session = nil
        say "new conversation. #{RubyClaw.tools.size} tools ready."
        :handled
      when "/help", "/?"
        say HELP
        :handled
      when "/prefer", "/remember"
        text = rest.join(" ")
        say(text.empty? ? "  usage: /prefer <how you want me to work>" : "  " + Notes.append(:preference, text))
        :handled
      when "/notes"
        Notes.ensure!
        Notes::FILES.each do |kind, path|
          body = Notes.read(kind)
          say "  #{File.basename(path)} — #{body.lines.size} line(s)"
          body.lines.reject { |l| l.start_with?("#", "<!--") }.last(5).each { |l| say "    #{l.chomp}" }
        end
        skills = Notes.skill_files
        say "  skills/ — #{skills.size} skill(s): #{skills.keys.join(', ')}"
        :handled
      when "/tools"
        RubyClaw.tools.each { |n, t| say format("  %-16s [%s]", n, t.origin == "builtin" ? "core" : "self") }
        :handled
      when "/stats"
        inv = Consolidate.inventory
        inv.each { |t| say format("  %-16s %5d calls %4d errs  %s", t["name"], t["calls"], t["errors"], t["idle_days"] ? "idle #{t['idle_days']}d" : "never used") }
        :handled
      when "/model"
        say "  model    #{@model || RubyClaw.model_name}"
        say "  endpoint #{@base_url || RubyClaw.base_url}"
        say "  key      #{RubyClaw.api_key.to_s.empty? ? 'NOT SET' : 'set'} (#{RubyClaw.key_source})"
        :handled
      when "/evo"
        f = File.join(LOG_DIR, "evolution.jsonl")
        if File.exist?(f)
          File.readlines(f).last(10).each do |l|
            e = JSON.parse(l) rescue next
            say format("  %s %-6s %-18s %s", e["ts"][0, 16], e["kind"], e["name"], e["reason"].to_s[0, 50])
          end
        else
          say "  nothing grown yet"
        end
        :handled
      when "/rollback"
        n = (rest.first || "1").to_i
        if n < 1
          say "  usage: /rollback [n] — n must be 1 or more"
          return :handled
        end
        # HEAD~n..HEAD is n commits; HEAD~#{n - 1}..HEAD is n-1, so /rollback on its own
        # reverted nothing and just printed git's "empty commit set" error.
        out = `git -C #{ROOT} revert --no-edit HEAD~#{n}..HEAD 2>&1`
        say "  " + ($?.success? ? "reverted #{n} commit(s)" : out.strip)
        say "  (a core file change takes effect on the next start)"
        :handled
      else
        say "  unknown command. /help"
        :handled
      end
    end

    def say(s) = $stdout.puts(s)
  end
end
