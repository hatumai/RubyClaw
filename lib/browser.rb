# frozen_string_literal: true
# Drive a real browser: navigate, read the page as the browser rendered it, run JS,
# click, type, screenshot.
#
# This is CDP (Chrome DevTools Protocol) over the WebSocket client in ws.rb -- no gem, no
# wrapper library. Chromium runs headless in the background for the life of the harness,
# so the page keeps its cookies, its logged-in session and its scroll position from one
# tool call to the next, which is the whole point of having a browser rather than an HTTP
# client. `http` is still the right tool for a plain fetch; this is for pages that need
# JavaScript, a click, or a login.
#
# Events are deliberately ignored: CDP streams page/network events that a long-lived
# session would have to buffer and drain, and every one of them is a way for the socket
# to fill up. Instead the helpers poll for what they need (`document.readyState` after a
# navigation), which is simpler and has fewer failure modes.
#
# One caller at a time (@mutex). Under `claw up` a Telegram thread and the local prompt
# both reach this object, and two senders on one socket mismatch replies: each waits for
# its own message id and drops the ones that are not its own, so a reply is read by the
# wrong caller and thrown away, and the real owner waits out its timeout for an answer
# that was already consumed. The mutex is not re-entrant, so the public methods are thin
# wrappers around unlocked `*_locked` internals.
require "json"
require "net/http"
require "fileutils"
require_relative "ws"

module RubyClaw
  class Browser
    class << self
      def session
        @session_lock ||= Mutex.new
        @session_lock.synchronize { @session ||= new }
      end

      def close
        @session_lock ||= Mutex.new
        @session_lock.synchronize do
          @session&.stop!
          @session = nil
        end
      end
    end

    NAV_TIMEOUT = 30
    # A Chromium that *exists* but cannot execute here. Not a missing binary -- a binary for
    # the wrong machine or the wrong libraries. Measured on a Pi Zero 1 W (armv6, no NEON):
    # Debian's Chromium exits at once with "The hardware on this system lacks support for
    # NEON SIMD extensions", and every call spawned it again to hear the same answer.
    CANNOT_RUN = /lacks support for NEON|Illegal instruction|Exec format error|
                  |error while loading shared libraries|cannot execute binary file|wrong ELF class/x
    PROFILE_DIR = File.join(ROOT, "data", "browser")
    SHOT_DIR = File.join(ROOT, "data", "screenshots")
    VIEWPORT = "1280,900"
    STOP_GRACE = 5   # seconds to let chromium exit on TERM before KILL

    attr_reader :pid

    # The profile is where cookies, localStorage and logins live, so it is also where a
    # session survives a restart. Overridable because two harnesses on one machine must
    # not fight over the same Chromium lock.
    def initialize(binary: ENV["CLAW_BROWSER"], profile: ENV["CLAW_BROWSER_PROFILE"] || PROFILE_DIR)
      @binary = binary.to_s.empty? ? find_binary : binary.to_s
      @profile = profile
      @ws = nil
      @pid = nil
      @seq = 0
      @mutex = Mutex.new
      @at_exit_installed = false
    end

    def binary_missing?
      @binary.nil? || !File.executable?(@binary)
    end

    def alive?
      !@pid.nil? && !@ws.nil? && @ws.open?
    rescue StandardError
      false
    end

    # ---- lifecycle -----------------------------------------------------------

    def start!
      with_lock { start_locked }
    end

    def stop!
      # try_lock, because this also runs from the at_exit hook: an exit path must never
      # block on a command another thread is in the middle of, and killing the browser
      # from outside is safe -- the owner notices its socket has gone.
      if @mutex.try_lock
        begin
          stop_locked
        ensure
          @mutex.unlock
        end
      else
        stop_locked
      end
    end

    def start_locked
      return self if alive?

      # Answer from what this machine already told us rather than spawning a process we know
      # will die: on a machine whose browser cannot run at all, every tool call paid for
      # another doomed start. Sticky for the life of this object; `Browser.close` builds a
      # new one if the situation has changed (a different binary, a fixed install).
      raise Error, @cannot_run if @cannot_run

      raise Error, "no chromium binary found (set CLAW_BROWSER, or install chromium)" if binary_missing?

      FileUtils.mkdir_p(@profile)
      clear_stale_lock!
      log = File.join(@profile, "chromium.log")
      @log_path = log
      # --remote-debugging-port=0 lets the OS pick a free port, and chromium says which
      # one it chose on stderr; --no-sandbox because a harness is often run where the
      # kernel's user-namespace sandbox is unavailable (containers, some ARM kernels) and
      # a browser that refuses to start is worse than one without that belt.
      #
      # A filename for out/err is opened with O_TRUNC by Ruby, so the log of a previous
      # run -- including the ws:// URL it printed -- is gone before this one starts. That
      # matters after a reboot: a stale "DevTools listening on" line would otherwise be
      # read as this run's endpoint and every call would go to a port nothing is on.
      @pid = Process.spawn(@binary, *flags, "about:blank",
                           out: log, err: log, pgroup: true)
      # A harness that is killed must not leave a browser behind holding this profile:
      # the next start would find the lock and refuse. Once per object, not once per
      # start: a harness that restarts its browser fifty times does not need fifty
      # handlers running at exit.
      unless @at_exit_installed
        at_exit { stop! }
        @at_exit_installed = true
      end
      wait_for_endpoint
      @ws = WS.new(ws_url)
      self
    end

    def stop_locked
      @ws&.close
      @ws = nil
      pid = @pid
      return if pid.nil?

      signal("TERM", pid)
      # Wait for it to actually go. The next start must not find this one's SingletonLock
      # still held by a process that is on its way out, which is a real startup failure and
      # not a theoretical one.
      deadline = Time.now + STOP_GRACE
      sleep 0.05 while process_alive? && Time.now < deadline
      signal("KILL", pid) if process_alive?
      @pid = nil
    end

    # ---- high level ----------------------------------------------------------

    def open(url)
      with_lock do
        restart_if_dead
        res = cdp("Page.navigate", { url: url.to_s })
        if res["errorText"] && res["errorText"] != ""
          next "navigation failed: #{res['errorText']}"
        end

        settle
        "#{title_locked}\n#{url_locked}"
      end
    end

    def title
      with_lock { title_locked }
    end

    def url
      with_lock { url_locked }
    end

    def text
      with_lock { text_locked }
    end

    def html
      with_lock { html_locked }
    end

    def title_locked = evaluate_locked("document.title").to_s

    def url_locked = evaluate_locked("location.href").to_s

    def text_locked
      evaluate_locked("document.body ? document.body.innerText : ''").to_s
    end

    def html_locked = evaluate_locked("document.documentElement.outerHTML").to_s

    def evaluate(js, await: true)
      with_lock { evaluate_locked(js, await: await) }
    end

    def evaluate_locked(js, await: true)
      restart_if_dead
      res = cdp("Runtime.evaluate", { expression: js.to_s, returnByValue: true,
                                      awaitPromise: await, timeout: 20_000 })
      r = res["result"] || {}
      if res["exceptionDetails"]
        raise Error, "javascript raised: #{(res['exceptionDetails']['exception'] || {})['description'] || res['exceptionDetails']['text']}"
      end

      r["value"].nil? ? r["description"] : r["value"]
    end

    # A real mouse press at the element's centre, not element.click(): single-page apps
    # routinely ignore a synthetic click that arrives with no pointer events.
    def click(selector)
      with_lock { click_locked(selector) }
    end

    def click_locked(selector)
      restart_if_dead
      box = evaluate_locked(<<~JS)
        (() => {
          const el = document.querySelector(#{selector.to_s.to_json});
          if (!el) return null;
          el.scrollIntoView({ block: "center", inline: "center" });
          const r = el.getBoundingClientRect();
          const style = window.getComputedStyle(el);
          if (r.width === 0 || r.height === 0 || style.visibility === "hidden" || style.display === "none")
            return { hidden: true };
          return { x: r.left + r.width / 2, y: r.top + r.height / 2, tag: el.tagName.toLowerCase(),
                   text: (el.innerText || el.value || "").slice(0, 80) };
        })()
      JS
      raise Error, "no element matches #{selector}" if box.nil?
      raise Error, "#{selector} is not visible" if box.is_a?(Hash) && box["hidden"]

      x = box["x"].to_f.round
      y = box["y"].to_f.round
      click_at_locked(x, y)
      settle
      "clicked <#{box['tag']}> #{box['text'].to_s.strip.inspect} at #{x},#{y}"
    end

    def click_at(x, y)
      with_lock { click_at_locked(x, y) }
    end

    def click_at_locked(x, y)
      %w[mousePressed mouseReleased].each do |type|
        cdp("Input.dispatchMouseEvent", { type: type, x: x, y: y, button: "left",
                                          clickCount: 1, buttons: type == "mousePressed" ? 1 : 0 })
      end
    end

    def type(selector, value, submit: false)
      with_lock { type_locked(selector, value, submit: submit) }
    end

    def type_locked(selector, value, submit: false)
      restart_if_dead
      # focus + select, then insertText: selecting first is what makes this *replace* the
      # field's contents the way a person does. Without it, text was appended to whatever
      # was already in the box -- "typed by pagehello from the harness".
      focus = evaluate_locked(<<~JS)
        (() => {
          const el = document.querySelector(#{selector.to_s.to_json});
          if (!el) return null;
          el.scrollIntoView({ block: "center" });
          el.focus();
          if (typeof el.select === "function") el.select();
          return el.tagName.toLowerCase();
        })()
      JS
      raise Error, "no element matches #{selector}" if focus.nil?

      cdp("Input.insertText", { text: value.to_s })
      if submit
        key_locked("Enter")
        settle
      end
      "typed #{value.to_s.length} chars into <#{focus}>#{submit ? ' and pressed Enter' : ''}"
    end

    KEYS = {
      "Enter" => { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" },
      "Tab" => { key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 },
      "Escape" => { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 },
      "Backspace" => { key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 },
      "ArrowDown" => { key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40 },
      "ArrowUp" => { key: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38 }
    }.freeze

    def key(name)
      with_lock { key_locked(name) }
    end

    def key_locked(name)
      spec = KEYS[name.to_s] || KEYS["Enter"]
      %w[keyDown keyUp].each do |type|
        cdp("Input.dispatchKeyEvent", spec.merge(type: type))
      end
      "pressed #{name}"
    end

    # The screenshot lands inside the project (data/screenshots/) and the path comes back;
    # the caller decides what to do with it. A harness that can see images can open it.
    def screenshot(path = nil)
      with_lock { screenshot_locked(path) }
    end

    def screenshot_locked(path = nil)
      restart_if_dead
      res = cdp("Page.captureScreenshot", { format: "png", captureBeyondViewport: false })
      data = res["data"].to_s
      raise Error, "screenshot came back empty" if data.empty?

      target = path.to_s.empty? ? File.join(SHOT_DIR, "shot-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}.png") : path.to_s
      target = Paths.inside_root!(target, ROOT, "write")
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, data.unpack1("m"))
      "#{target} (#{File.size(target)} bytes)"
    end

    # The deadline is the caller's, and it does not hold the browser: no socket traffic
    # happens here, so a `wait` in one conversation must not stop another.
    def wait(ms)
      sleep(ms.to_i.clamp(0, 30_000) / 1000.0)
      "waited #{ms}ms"
    end

    # ---- CDP plumbing --------------------------------------------------------

    def call(method, params = {}, timeout: 30)
      with_lock { cdp(method, params, timeout: timeout) }
    end

    def cdp(method, params = {}, timeout: 30)
      restart_if_dead
      @seq += 1
      id = @seq
      @ws.send_text(JSON.generate(id: id, method: method, params: params))
      deadline = Time.now + timeout
      loop do
        left = deadline - Time.now
        raise Error, "CDP #{method} timed out after #{timeout}s" if left <= 0

        msg = begin
          JSON.parse(@ws.recv(timeout: left))
        rescue JSON::ParserError
          next                     # events are JSON, but never needed here
        end
        next unless msg["id"] == id      # an event: dropped on purpose

        if msg["error"]
          raise Error, "CDP #{method} failed: #{msg['error']['message']}"
        end

        return msg["result"] || {}
      end
    rescue Error, IOError, SystemCallError
      # The browser died or the socket broke. Kill whatever is left rather than just
      # forgetting the pid -- that used to leave a chromium running with no handle on it,
      # which is also how the next start inherited a live SingletonLock -- and let the next
      # call start a new one instead of limping on with a dead channel.
      stop_locked
      raise
    end

    def restart_if_dead
      return if alive?

      stop_locked
      @seq = 0
      start_locked
    end

    # Give the page a moment to finish whatever the last action started. Polling
    # readyState, not sleeping blindly: a local page is ready immediately, a real one
    # usually within a few hundred ms. Internal: called from inside the lock.
    def settle(timeout: NAV_TIMEOUT)
      deadline = Time.now + timeout
      loop do
        return true if evaluate_locked("document.readyState", await: false).to_s == "complete"
        return false if Time.now >= deadline

        sleep 0.15
      end
    rescue Error
      nil
    end

    def flags
      ["--headless=new", "--no-sandbox", "--disable-setuid-sandbox", "--disable-gpu",
       "--disable-dev-shm-usage", "--no-first-run", "--no-default-browser-check",
       "--disable-background-networking", "--disable-sync", "--mute-audio",
       "--remote-debugging-port=0", "--user-data-dir=#{@profile}", "--window-size=#{VIEWPORT}"]
    end

    def find_binary
      %w[chromium chromium-browser google-chrome google-chrome-stable chrome].each do |name|
        path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                  .map { |d| File.join(d, name) }.find { |p| File.executable?(p) }
        return path if path
      end
      nil
    end

    # Chromium prints the chosen port on stderr once it is listening.
    def wait_for_endpoint(timeout: 25)
      deadline = Time.now + timeout
      loop do
        log = File.exist?(@log_path) ? File.read(@log_path) : ""
        if (m = log.match(%r{DevTools listening on (ws://[^\s]+)}))
          @endpoint = m[1]
          return @endpoint
        end
        if @pid && !process_alive?
          why = log.strip.lines.last(4).join(" ")[0, 300]
          if why.match?(CANNOT_RUN)
            # Say what the machine said, and mark it so the next call does not repeat it.
            @cannot_run = "this machine's Chromium cannot run here: #{why.strip}"
          end
          raise Error, "chromium exited on startup: #{why}"
        end
        raise Error, "chromium did not start within #{timeout}s: #{log.strip.lines.last(3).join(' ')[0, 200]}" if Time.now >= deadline

        sleep 0.2
      end
    end

    # Chromium refuses to start when a SingletonLock is present, and that lock is a
    # symlink to "<hostname>-<pid>" which outlives both a crash and a reboot -- so after
    # a restart the machine finds a lock from a process that no longer exists and the
    # browser will not come up. If the pid in it is not running, the lock is stale.
    def clear_stale_lock!
      lock = File.join(@profile, "SingletonLock")
      return unless File.symlink?(lock) || File.exist?(lock)

      target = begin
        File.readlink(lock)
      rescue StandardError
        ""
      end
      pid = target[/-(\d+)\z/, 1].to_i
      alive = begin
        pid.positive? && Process.kill(0, pid) && true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
      return if alive

      FileUtils.rm_f([lock, File.join(@profile, "SingletonCookie"), File.join(@profile, "SingletonSocket")])
    end

    # Whether our chromium is still running. kill(0, pid) alone is wrong twice: it is true
    # for a zombie, so a crashed browser looks alive, and it never reaps. Ask WNOHANG first
    # -- if the child has exited, that call reaps it and hands back its pid.
    def process_alive?
      pid = @pid
      return false if pid.nil?

      if Process.waitpid(pid, Process::WNOHANG)
        @pid = nil
        return false
      end
      Process.kill(0, pid)
      true
    rescue Errno::ECHILD, Errno::ESRCH, Errno::EPERM
      @pid = nil
      false
    end

    def signal(name, pid)
      Process.kill(name, -pid)     # the whole group: chromium's own children too
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # CDP's page target, not the browser endpoint: opening a page target directly means
    # no session multiplexing, which is one less moving part.
    def ws_url
      host = @endpoint[/ws:\/\/([^\/]+)/, 1]
      list = Net::HTTP.get(URI("http://#{host}/json/list"))
      targets = JSON.parse(list)
      page = targets.find { |t| t["type"] == "page" && t["webSocketDebuggerUrl"] }
      return page["webSocketDebuggerUrl"] if page

      # Nothing open (chromium started without a page target): ask for one.
      uri = URI("http://#{host}/json/new?about:blank")
      req = Net::HTTP::Put.new(uri)
      created = JSON.parse(Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }.body)
      created["webSocketDebuggerUrl"] or raise Error, "no page target available"
    end

    def with_lock(&)
      @mutex.synchronize(&)
    end
  end
end
