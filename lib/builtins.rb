# frozen_string_literal: true
# The builtin surface: what the model gets before it has written anything of its own.
#
# A small, stable schema set is what keeps the prompt cache warm, and most new capability
# belongs in `extend` -- a tool the model writes itself. A capability earns a place here
# only when the model *cannot* write it: it needs the harness's own lifecycle (a shell
# that stays open between calls, a browser process that stays alive), or durable state
# the harness owns (the job store in schedule.rb). `remember`, `read_file` and the rest
# serve the same purpose: no amount of self-written code can give a stateless tool a
# memory.
#
# So the list is ten and the rule is unchanged: growth happens in the instance's own
# tools/ directory (instance/tools/), and this file changes only when the harness gains
# a capability of its own.
require "net/http"
require "uri"
require "shellwords"
require_relative "term"
require_relative "browser"
require_relative "schedule"
require_relative "work"

module RubyClaw
  TOOL_TIMEOUT = 120

  def self.run_shell(cmd, timeout: TOOL_TIMEOUT, cwd: ROOT)
    r = Proc.run(Proc.shell_command(cmd), timeout: timeout, cwd: cwd)
    body = [r.out, r.err].reject(&:empty?).join("\n").strip
    return "TIMEOUT after #{timeout}s (process group killed)#{body.empty? ? '' : "\n#{body}"}" if r.timed_out

    "#{body}\n[exit #{r.code}]"
  end

  # Every path a tool touches resolves inside the project, or it is refused. An
  # absolute path or ../.. used to work, which meant the model could write
  # ~/.bashrc or .ssh/authorized_keys from a tool call. The shell tool is the
  # honest escape hatch for anything outside -- it says so in its own description.
  module Paths
    class << self
      def inside_root!(path, root = ROOT, what = "touch")
        raise Error, "path is required" if path.to_s.strip.empty?
        abs = File.expand_path(path.to_s, root)
        unless abs == root || abs.start_with?(root + File::SEPARATOR)
          raise Error, "refusing to #{what} #{abs}: it is outside the project (#{root}). " \
                       "Use the sh tool if you really mean an absolute path."
        end
        raise Error, "refusing to #{what} #{abs}: .git is not a workspace" if abs.include?("/.git/")

        abs
      end
    end
  end

  # ---- builtins ------------------------------------------------------------

  tool "sh", origin: "builtin",
    description: "Run a shell command on this machine (bash -lc where bash exists, sh -c " \
                 "otherwise; cwd = project root, default 120s timeout). Returns stdout+stderr " \
                 "and the exit status. This is your hands: it runs unsandboxed as the user " \
                 "claw runs as, and it is the only tool that is not confined to the project.",
    params: { "command" => { type: "string", description: "shell command" },
              "cwd"     => { type: "string", required: false, description: "working dir (optional)" } } do |a|
    run_shell(a["command"], cwd: a["cwd"] || ROOT)
  end

  tool "read_file", origin: "builtin",
    description: "Read a text file. Paths may be absolute or relative to the project root.",
    params: { "path" => { type: "string" },
              "offset" => { type: "integer", required: false,
                            description: "1-indexed first line (optional, default 1)" },
              "limit" => { type: "integer", required: false,
                           description: "max lines (optional, default 400)" } } do |a|
    p = File.expand_path(a["path"], ROOT)
    raise Error, "no such file: #{p}" unless File.file?(p)
    off = [(a["offset"] || 1).to_i - 1, 0].max        # 0 and negatives were indexing from the end
    lim = [(a["limit"] || 400).to_i, 1].max
    # Read only what was asked for. File.readlines pulled the whole file in first:
    # `limit: 3` on a 100 MB log measured 20 MB -> 274 MB of RSS, which is an OOM on
    # a Pi. Binary files are scrubbed rather than returned as invalid UTF-8, which
    # JSON.generate refuses and which used to poison every later request in the turn.
    out = []
    File.open(p, "rb") do |io|
      io.each_line.with_index do |line, i|
        next if i < off
        break if out.size >= lim

        out << "#{format('%5d|', i + 1)}#{RubyClaw.utf8(line.chomp)}"
      end
    end
    out.join("\n")
  end

  tool "write_file", origin: "builtin",
    description: "Create or overwrite a text file inside the project with exact content. " \
                 "Parent dirs are created. Paths outside the project, and anything under " \
                 "lib/ or .git/, are refused. Prefer this over shell heredocs for files. " \
                 "To add a tool, use `extend` — it validates before the code goes live.",
    params: { "path" => { type: "string" }, "content" => { type: "string" } } do |a|
    p = Paths.inside_root!(a["path"], ROOT, "write")
    if p.start_with?(File.join(ROOT, "lib") + File::SEPARATOR)
      raise Error, "refusing to write #{p}: lib/ is the frozen core. Patch it with " \
                   'extend kind:"core" (staged, boot-probed, committed) so a bad patch ' \
                   "cannot go live unreviewed."
    end
    raise Error, "refusing to write through the symlink #{p}" if File.symlink?(p)

    FileUtils.mkdir_p(File.dirname(p))
    # Re-check after mkdir: a symlinked subdirectory could point outside the project.
    Paths.inside_root!(File.dirname(p), ROOT, "write")
    File.write(p, a["content"])
    "wrote #{a['content'].bytesize} bytes to #{p}"
  end

  tool "grep", origin: "builtin",
    description: "Search file contents under a path. Uses ripgrep when present, grep otherwise.",
    params: { "pattern" => { type: "string" },
              "path" => { type: "string", required: false,
                          description: "dir or file (default: project root)" },
              "glob" => { type: "string", required: false, description: "e.g. '*.rb'" } } do |a|
    raise Error, "grep needs a pattern" if a["pattern"].to_s.strip.empty?
    dir = File.expand_path(a["path"] || ROOT, ROOT)
    # `--` before the pattern: a pattern that starts with a dash is a pattern (a log line
    # being searched for, "--version"), not an option. Without it grep answered `grep
    # pattern --pre=cat` with "unrecognized option '--pre=cat'".)
    if system("command -v rg >/dev/null 2>&1")
      cmd = ["rg", "-n", "--no-heading", "-S", "-m", "60"]
      cmd += ["-g", a["glob"]] if a["glob"]
      cmd += ["--", a["pattern"], dir]
      run_shell(cmd.shelljoin)
    else
      cmd = ["grep", "-rn", "--exclude-dir=.git", "--include=#{a["glob"] || '*'}", "-m", "60",
             "--", a["pattern"], dir]
      run_shell(cmd.shelljoin)
    end
  end

  tool "http", origin: "builtin",
    description: "HTTP request (stdlib, no deps). Returns status, headers of interest, and body text.",
    params: { "url" => { type: "string" },
              "method" => { type: "string", required: false, description: "GET/POST/... default GET" },
              "body" => { type: "string", required: false, description: "request body" },
              "headers" => { type: "object", required: false, description: "extra headers" } } do |a|
    raise Error, "http needs a url (e.g. https://example.com/page)" if a["url"].to_s.strip.empty?

    uri = URI(a["url"])
    klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put,
              "DELETE" => Net::HTTP::Delete, "HEAD" => Net::HTTP::Head }[a["method"].to_s.upcase] || Net::HTTP::Get
    req = klass.new(uri)
    req["User-Agent"] = "rubyclaw/0.1"
    (a["headers"] || {}).each { |k, v| req[k] = v }
    req.body = a["body"] if a["body"]
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                          open_timeout: 20, read_timeout: 60) { |h| h.request(req) }
    "#{res.code} #{res.message}\ncontent-type: #{res['content-type']}\n\n#{res.body}"
  end

  tool "remember", origin: "builtin",
    description: "Write one durable line that is injected into every future system prompt, so it " \
                 "survives restarts and new conversations. kind='preference' records how the " \
                 "user wants you to work (tone, length, format, a standing rule, something to " \
                 "avoid) and is honoured from your next request onward — use it whenever they " \
                 "correct you or state a preference. kind='memory' (the default) records a fact " \
                 "about this machine, this project or the world. Keep either to one short line.",
    params: { "note" => { type: "string" },
              "kind" => { type: "string", required: false, enum: %w[memory preference],
                          description: "preference = how to behave; memory = a fact. Default: memory" } } do |a|
    kind = a["kind"].to_s == "preference" ? :preference : :memory
    "#{Notes.append(kind, a['note'])} — active from your next request"
  end

  tool "term", origin: "builtin",
    description: "Run a command in a shell that STAYS OPEN between calls: the working " \
                 "directory, exported variables and shell state carry over, so `cd /tmp` " \
                 "then `pwd` in the next call sees /tmp. Use it for multi-step work; use " \
                 "`sh` for a one-off that should leave nothing behind. State is lost " \
                 "(and reported) if a command exceeds its timeout, exits the shell, or the " \
                 "harness restarts. Not for interactive programs: there is no terminal.",
    params: { "command" => { type: "string", description: "shell command" },
              "timeout" => { type: "integer", required: false,
                             description: "seconds (optional, default 60)" } } do |a|
    raise Error, "term needs a command" if a["command"].to_s.strip.empty?

    session = Term.session
    # Clamped at both ends: 0 or a negative number used to be handed to the kernel, and a
    # model asking for 60000 "seconds" held the call (and the conversation) for 16 hours.
    secs = a["timeout"].to_i
    secs = 60 if secs.zero?
    out, status, cwd, timed_out, restarted = session.run(a["command"], timeout: secs.clamp(1, 600))
    lines = []
    lines << "restarted the shell: the previous one exited, so any cd/export is gone" if restarted && !timed_out
    if timed_out
      lines << "TIMEOUT — the command outran its deadline and the whole process group was " \
               "killed, which also cost the shell session. State is gone; a new shell starts " \
               "on the next call."
    end
    lines << "cwd: #{cwd}"
    body = out.to_s.strip
    body = "#{body[0, 20_000]}\n…[truncated #{body.bytesize - 20_000} bytes]" if body.bytesize > 20_000
    lines << body unless body.empty?
    lines << "[exit #{status}]" unless status.nil?
    lines.join("\n")
  end

  tool "browser", origin: "builtin",
    description: "Drive a real headless Chromium: it renders JavaScript, keeps cookies and " \
                 "logins between calls, and stays on the same page until you navigate away " \
                 "or close it. Actions: open(url) | text | html | title | url | eval(js) | " \
                 "click(selector) | type(selector, text, submit) | key(name) | shot(path) | " \
                 "wait(ms) | close | status. Use it instead of `http` for anything that " \
                 "needs JavaScript, a click, or a session; use `http` for a plain fetch, " \
                 "which is far cheaper.",
    params: { "action" => { type: "string", description: "open|text|html|title|url|eval|click|type|key|shot|wait|close|status" },
              "url" => { type: "string", required: false },
              "selector" => { type: "string", required: false, description: "CSS selector" },
              "text" => { type: "string", required: false },
              "js" => { type: "string", required: false },
              "path" => { type: "string", required: false, description: "screenshot path (default: data/screenshots/)" },
              "submit" => { type: "boolean", required: false, description: "press Enter after typing" },
              "ms" => { type: "integer", required: false } } do |a|
    b = Browser.session
    case a["action"].to_s.downcase
    when "open", "goto", "navigate"
      raise Error, "browser open needs a url" if a["url"].to_s.strip.empty?

      b.open(a["url"])
    when "text"   then b.text
    when "html"   then b.html
    when "title"  then b.title
    when "url"    then b.url
    when "eval", "js", "javascript", "evaluate"
      raise Error, "browser eval needs js" if a["js"].to_s.strip.empty?

      b.evaluate(a["js"]).inspect
    when "click"
      raise Error, "browser click needs a selector" if a["selector"].to_s.strip.empty?

      b.click(a["selector"])
    when "type", "fill"
      raise Error, "browser type needs a selector and text" if a["selector"].to_s.strip.empty?

      b.type(a["selector"], a["text"].to_s, submit: a["submit"] ? true : false)
    when "key"    then b.key(a["text"] || a["selector"] || "Enter")
    when "shot", "screenshot" then b.screenshot(a["path"])
    when "wait"   then b.wait(a["ms"] || 1000)
    when "close"  then b.stop!; "browser closed"
    when "status" then b.alive? ? "running (pid #{b.pid}) on #{b.url}" : "not running"
    else
      raise Error, "unknown browser action #{a['action'].inspect}: use open|text|html|title|url|eval|click|type|key|shot|wait|close|status"
    end
  end

  tool "schedule", origin: "builtin",
    description: "Recurring work on this machine that survives a reboot: the job store is " \
                 "data/schedule.json and `claw schedule install-boot` puts a cron entry in " \
                 "place (a job that missed its window while the machine was off runs once, " \
                 "late). Actions: add(name, spec, command) | list | remove(name) | " \
                 "enable(name) | disable(name) | run(name) [runs it now] | log(name). Specs: " \
                 "\"every 15m\", \"hourly\", \"daily 07:30\", \"weekly mon 08:00\". A shell " \
                 "job runs a command here; a task job (mode: task) is a prompt the harness's " \
                 "own model answers. deliver: telegram sends the result to the bot's allowed " \
                 "chats.",
    params: { "action" => { type: "string", description: "add|list|remove|enable|disable|run|log" },
              "name" => { type: "string", required: false },
              "spec" => { type: "string", required: false, description: "every 15m | hourly | daily 07:30 | weekly mon 08:00" },
              "command" => { type: "string", required: false },
              "mode" => { type: "string", required: false, enum: %w[shell task],
                          description: "shell = a command (default); task = a prompt for the model" },
              "deliver" => { type: "string", required: false, enum: %w[log telegram],
                             description: "where the result goes (default log)" },
              "timeout" => { type: "integer", required: false } } do |a|
    case a["action"].to_s.downcase
    when "add", "create"
      job = Schedule.add(name: a["name"], spec: a["spec"], command: a["command"],
                         mode: a["mode"] || "shell", deliver: a["deliver"] || "log",
                         timeout: a["timeout"])
      "scheduled #{job['name']}: #{Schedule.describe(job)} (#{job['mode']}, deliver: #{job['deliver']}). " \
        "It is due now, so it runs on the next tick — `claw schedd --once`, or while `claw up` is " \
        "running. Survive a reboot: `claw schedule install-boot`."
    when "list", "ls"
      jobs = Schedule.load
      next "no schedules yet" if jobs.empty?

      jobs.map do |j|
        nxt = Schedule.next_run_display(j)
        format("%-18s %-16s next %s  %-8s %d run(s)  %s %s", j["name"], Schedule.describe(j), nxt,
               j["enabled"] == false ? "paused" : (j["last_status"] || "never"), j["runs"].to_i,
               j["mode"], j["command"].to_s[0, 40])
      end.join("\n") + "\nboot persistence: #{Schedule.boot_installed? ? 'installed (cron)' : 'NOT installed'}"
    when "remove", "rm", "delete"
      Schedule.remove(a["name"]) ? "removed #{a['name']}" : "no schedule called #{a['name']}"
    when "enable", "disable"
      job = Schedule.set_enabled(a["name"], a["action"].to_s.downcase == "enable")
      "#{a['action'].to_s.downcase}d #{job['name']}"
    when "run", "now"
      job = Schedule.load.find { |j| j["name"] == a["name"] } or next "no schedule called #{a['name']}"
      r = Schedule.run_job(job)
      "#{r['name']}: #{r['ok'] ? 'ok' : 'FAILED'} in #{r['seconds']}s\n#{r['output'].to_s.strip[0, 1500]}"
    when "log"
      path = Schedule.log_path(a["name"])
      next "no log for #{a['name']} yet" unless File.exist?(path)

      File.readlines(path).last(30).join
    else
      "unknown schedule action #{a['action'].inspect}: use add|list|remove|enable|disable|run|log"
    end
  end

  tool "extend", origin: "builtin",
    description: "Grow yourself. kind='tool' writes a new Ruby tool into instance/tools/ " \
                 "(source must call RubyClaw.tool with a block); kind='skill' writes a markdown " \
                 "procedure into instance/skills/; kind='core' stages a patch to lib/. Every kind " \
                 "is syntax-checked, loaded and exercised in a throwaway child process, and " \
                 "git-committed only if it passes. tool/skill are live immediately; core takes " \
                 "effect on next start. Pass test='{...}' (JSON args) to prove the new tool " \
                 "actually answers correctly.",
    params: { "kind"    => { type: "string", enum: %w[tool skill core], description: "what to grow" },
              "name"    => { type: "string", description: "tool or skill name (snake_case)" },
              "source"  => { type: "string", description: "full Ruby or markdown source" },
              "reason"  => { type: "string", description: "one line: why this is worth keeping" },
              "test"    => { type: "string", required: false,
                             description: "JSON object of args to call the new tool with" },
              "replace" => { type: "boolean", required: false,
                             description: "overwrite an existing tool/skill of this name" } } do |a|
    SelfWrite.propose(kind: a["kind"], name: a["name"], source: a["source"],
                      reason: a["reason"], test: a["test"], replace: a["replace"])
  end
end
