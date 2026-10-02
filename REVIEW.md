# Code review — RubyClaw 0.03 → 0.04

This is the record of a full review of the harness: the findings, how each one was
demonstrated, what changed, and what is still open. Anyone reading this code critically
should start here.

**Method.** Five parallel reviewers read the tree independently (CLI and core loop,
self-write and consolidation, the tool boundary, tests and tooling, docs against code),
and I ran my own measurement sweep: `ruby -c` and `-w` over every file, grep sweeps for
`eval`/`send`/`const_get`, `TODO`/`FIXME`/`binding.irb`, dead code and trailing
whitespace, plus rubocop 1.91 (baseline: 1,140 offenses on defaults — 9 Lint/Security,
43 Metrics, the rest Style, which this project does not enforce).

**The rule I held myself to:** a finding is only "fixed" when the failure it describes
can no longer be reproduced, and the reproduction becomes a test. The six findings in
the first section below were not theoretical — each one was run against the harness as a
working exploit before anything changed, and each exploit is now a test in
`test/hardening_test.rb`.

---

## Fixed: the self-write path

**A proposal could write its own verdict.** The parent ran the child, took the **last
line of its stdout** as the verdict, and promoted on it. A tool whose source printed a
passing verdict line and called `exit!(0)` was promoted — and it always raised when
called. The verdict is now written to a file whose name the parent chooses and tags with
a nonce, and only read when the child exited 0. *Test: `hardening_test.rb`.*

**A planted symlink in `.staging` could reach `lib/`.** Staging used a predictable path
(`.staging/<name>.rb`), so a symlink there pointing at `../lib/boot.rb` made an
`extend` write *through* it: `lib/boot.rb` went from 5,968 bytes to 71 and the tree
stopped booting, while the rejection message said "Nothing was written and nothing is
live." Staging is now a random-named file in a 0700 directory, opened
`O_EXCL|O_NOFOLLOW`. *Test: `hardening_test.rb`.*

**The boot probe accepted the string `BOOT_OK`.** A core patch that printed
`BOOT_OK 999 tools: totally fake` and exited 0 was committed as `self(core)` — and then
satisfied the probe on every later start, which meant the two-strike auto-revert could
never fire again. The probe now cross-checks the tool inventory the child reports, and
the revert undoes the commit recorded at promotion time rather than pattern-matching a
`self(core)` subject at HEAD (any later commit used to hide it). *Test: two of them,
including the auto-revert, which had no test at all.*

**The A/B merge gate could be defeated by scoring.** The merged tool is loaded in the
child that scores the replay, so it could redefine `RubyClaw.similarity` there: a merge
returning `TOTALLY DIFFERENT ANSWER` scored 1.0 and was committed. The child now returns
raw output only and the **parent** scores it; a merge whose tool fails to register is
rejected too. *Test: `hardening_test.rb`.*

**Child scripts executed on `require`.** `child_ab.rb` and `child_validate.rb` ran their
whole body at load, so any sweep that required every file crashed with a `TypeError` on
`File.basename(nil)`. Both now define their work and run it only under
`if $PROGRAM_NAME == __FILE__`, and both rescue `StandardError, ScriptError` instead of
`Exception`.

**`consolidate` staged its merge candidate on a predictable path** — the same symlink
problem, one file over. It now stages through the same hardened helper as any other
proposal, and its replay runs under the deadline-honest process runner instead of
`Timeout.timeout` (which does not, in fact, bound a child that leaves a grandchild
holding the pipes).

## Fixed: the tool boundary

**`write_file` had no path confinement.** `File.expand_path(path, ROOT)` happily accepts
`../../..` and absolute paths, so a model-decided argument could write anywhere the
process could — and a model's arguments are attacker-influenced text. There is now one
`RubyClaw::Paths.inside_root!` that refuses anything outside the project, refuses the
frozen core, and is what every writing path goes through. `read_file` clamps a zero or
negative offset (`lines[-2..]` read from the end of the file instead of failing).

**Binary tool output poisoned the conversation.** Output was cleaned with
`String#scrub` — but on an ASCII-8BIT string *every byte is valid*, so scrub is a no-op
and the invalid UTF-8 reached `JSON.generate`, which raised and killed the turn. Because
the poisoned message stayed in the conversation, every later turn died the same way. One
`RubyClaw.utf8` helper now forces UTF-8 before scrubbing, at every boundary (process
output, file reads, tool results, error messages), and truncation can no longer split a
character in half.

**`tools/feed_items.rb` used `URI.open`** (rubocop `Security/Open`): open-uri honours
`file://` and `|command`. The tool now uses `Net::HTTP` like the builtin does.

**Redaction only looked at field names.** A key named `url` containing
`?api_key=sk-…`, or an `Authorization: Bearer …` header, went into `log/usage.jsonl` —
a file that is replayed, committed, and read by the audit. Values are now scanned for
credential shapes too.

**`run_shell` could hang forever.** It wrote to pipes with no reader, so a command whose
grandchild inherited stdout blocked the read until the shell exited — no timeout could
save it. New `lib/proc.rb`: output goes to temp files, the child gets its own process
group, and a timeout signals the whole group.

## Fixed: sessions and surfaces

- **`override!` ignored a real credential** once `@api_key` was memoised, so the wizard
  verified the key it already had and `claw model` named the wrong source. (Its symptom
  was a failing test the reviewers ran into: `test/boot_test.rb` expected the key it had
  just set and got the machine's.)
- **The repo's real `.env` leaked into every in-process test.** `dotenv` does
  `ENV[k] ||= v`, so deleting a variable was not enough — the next `RubyClaw.config` call
  restored the real key. `CLAW_NO_DOTENV` pins the environment; sandboxed children
  unset it and read their own `.env` exactly as production does.
- **Telegram chunking split the wrong things.** An over-long line's pieces were emitted
  *before* the lines that preceded them, so text arrived out of order; and chunk length
  was counted in characters where Telegram counts UTF-16 units, so 4,000 emoji was sent
  as one chunk and rejected. Both fixed, both tested.
- **A dropped poll killed the bot.** Under `claw up` the bot thread died with a stderr
  line; now it backs off and keeps listening, and gives up only after six consecutive
  failures.
- **Non-interactive setup kept only the first allowed chat id.**
- **The wizard wrote `.env` and chmod-ed it afterwards**, so under a loose umask the key
  sat at 0664 — readable by every user on the box — until the chmod ran, and a crash
  left it that way permanently. Both files are written atomically, 0600 from birth;
  `YAML.safe_load_file` replaces the unsafe loader that could instantiate objects from a
  config the wizard itself rewrites.
- **`claw run --model X "task"` sent the flags to the model as part of the task**, and a
  flag with no value was dropped silently (so the real model was used).

## Fixed: tests and tooling

- `test/builtins_test.rb` asserted the *unsafe* `write_file` behaviour (writing outside
  the tree) and used a regex loose enough to pass for almost any output; both tightened.
- Three tests captured an exit status and never checked it; one test asserted against
  whatever `ruby` the machine happened to have; the relocator tests now skip on a machine
  without python3/perl instead of erroring.
- Tests pin their environment rather than only deleting variables, so an in-process test
  cannot pick up a real credential through dotenv.
- `.rubocop.yml` + `rake lint` (Lint + Security, clean) and `rake lint:metrics`
  (advisory). `TargetRubyVersion` is load-bearing: without it rubocop parsed as Ruby 2.7
  and **silently skipped whole files**, which is how an offense hides behind a syntax
  complaint.
- `test/hardening_test.rb` — 18 tests, one per failure described above.

**Result: 132 runs, 762 assertions, 0 failures, 0 errors, 0 skips. `rake lint`: no
offenses.**

## Added in 0.05: scheduling, a browser, a terminal that stays put

Three capabilities, each with the reason it had to be *builtin* rather than self-written: they need
the harness's own lifecycle or state the harness owns. Every one of them was driven end to end
against the real thing before being called done, and the bugs that found are below.

**The scheduler** keeps jobs in `data/schedule.json` (atomic writes, an flock for read-modify-write,
because the daemon, `claw schedule add` and a cron tick can be live at once). It runs in-process
while `claw up` is alive *and* from cron (`claw schedule install-boot` writes a marked block into the
user's own crontab: `@reboot` plus every five minutes). Two rules make a reboot harmless: a missed
window runs **once**, late, with the next run computed from *now* — not from the missed slot, which
would fire a burst to catch up — and a job that has never run is due immediately.

**The browser** is Chromium over CDP, with a WebSocket client written against the stdlib
(`lib/ws.rb`) because Ruby ships none and this project ships no gems. Real navigation, real
`Input.dispatchMouseEvent` clicks, real keystrokes, screenshots into `data/screenshots/`, and a
profile under `data/browser/` so cookies and logins outlive a restart.

**The terminal** (`term`) is a shell that stays open between calls: `cd` and `export` carry over,
which is the one thing `sh` deliberately does not do. Each call appends a marker line carrying a
nonce, the exit status and the new working directory, so the end of a command is unambiguous even
when the command prints the marker text itself.

### The bugs that found, all of them real

1. **A WebSocket payload of exactly 127 bytes desynchronised the stream** — the parser read the
   16-bit extended length and then, because it used two `if`s instead of `if/elsif`, read eight more
   bytes as a 64-bit length. It happened on Chrome's own response, and from the caller's side it
   looked like `websocket frame too large (8872770094665184812 bytes)` — that number is the JSON
   `{"id":1,` read as an integer. Every length boundary is now tested against bytes rather than
   against a browser, which is what found it and what would have found it earlier.
2. **Any 50 ms gap in the byte stream was reported as a timeout**, which aborted a read in the middle
   of a frame — and the bytes already taken off the socket are gone, so the next header came from
   inside a payload. Polling now waits for the deadline rather than for the next packet.
3. **A stale `SingletonLock` blocks Chromium after a reboot.** The lock is a symlink to
   `hostname-pid` and outlives the process that made it, so a machine coming back from a power cut
   found a lock from a process that no longer existed and refused to start the browser. A dead pid
   in the lock now means the lock goes.
4. **A crashed harness left Chromium running** (no `at_exit`), which is what produced the stale lock
   in the first place.
5. **The persistent shell was not killed on a timeout** — it was left mid-`sleep`, and the next call
   wrote into a dead pipe and read a stale marker. A timeout now kills the process group, marks the
   session unusable, and tells the caller its state is gone.
6. **Two parser details in the same shell**: a greedy regex swallowed every line after the marker
   (multi-line output lost all but its first line), and `Process.kill(0, pid)` is true for a zombie,
   so a killed shell looked alive.

## Round 3: 32-bit ARM, on real hardware (0.07)

Everything before this was verified on one machine. A Raspberry Pi Zero W was provisioned
(armv6l, Raspbian 13, 1 core, 426 MB) and asked for the browser test to be included and for
Chromium to be assumed present -- it is, on that image.

**The browser cannot run there, and the finding is the vendor's, not a guess.** `/usr/bin/chromium`
ships with the image, but armv6 has no NEON and Debian's Chromium has required it since 2023:

    The hardware on this system lacks support for NEON SIMD extensions.

The harness relayed exactly that sentence and exited cleanly -- no orphan, no zombie, no stale lock,
no memory blow-up -- which is the behaviour that matters when a browser is broken rather than
absent. Two real defects came out of it:

- **The browser tests errored instead of skipping.** `setup` skipped only when no binary was on
  `PATH`, so on a board whose Chromium exists but cannot execute, ten tests errored and the suite
  went red on a platform the harness supports. Starting the browser per test would cost a minute
  on a slow board, so the file now probes once per run and skips with the machine's own words;
  anything other than "cannot run here" still lands as a failure.
- **A doomed binary was spawned on every call.** Each tool call paid for another process that died
  immediately. `lib/browser.rb` now recognises a platform refusal (`CANNOT_RUN`: NEON, `Illegal
  instruction`, `Exec format error`, missing shared libraries, `wrong ELF class`) and answers from
  what the machine already said. It is deliberately narrow: an ordinary startup failure must not
  latch, or a working machine would be poisoned by one bad flag -- both directions are covered in
  `test/browser_nobrowser_test.rb`, which needs no browser and so runs on every machine.

**The installer's refusal path is now measured, not argued.** With no Ruby on the board at all,
`./rubyclaw` printed the no-prebuilt explanation and fetched nothing: `~/.cache` was 28 KB before
and after, no `~/.rubyclaw`, no tarball. Ruby 3.3.7 from `apt` (arm-linux-gnueabihf) then ran the
harness unchanged: `selftest` 15/15, the hand-written WebSocket framing green on 32-bit, the
persistent shell green, and a real model call (OpenRouter, free tool-capable model) drove `sh` and
returned `armv6l`.

**Running as a service was not actually supported.** Three gaps, all found by deploying it there:

- `serve` fell through to the prompt after starting Telegram, and the prompt breaks on the first
  EOF, so under a supervisor handing it `/dev/null` the bot came up and then took the process down
  with it. `claw up --telegram-only` runs the bot with no prompt. Two tests run the real entry
  point with a closed stdin: one asserts the process is still alive after three seconds and stops
  cleanly on TERM; the other asserts a bot that cannot start exits non-zero with the reason
  instead of idling silently with no bot.
- `install-boot` armed the scheduler at boot and left the bot behind, so a reboot brought one
  half back. `--serve` adds a second marked block (and `remove-boot --serve` removes both).
- output was block-buffered when stdout was not a terminal, so a service log stayed empty until
  4 KB accumulated -- unattended and apparently dead. `$stdout.sync = true`.
- and, found by re-reading the diff rather than by a test: `@reboot` is one-shot, so a bot that
  crashed at 3 a.m. stayed down until someone rebooted the board. The serve block now carries a
  five-minute keeper alongside the boot line, exactly as the scheduler's block does, and the bot
  writes `data/serve.pid` once it is connected so a keeper run is a no-op while it is up (two
  pollers on one token steal each other's messages) and cannot be fooled by a start that failed.
  Removing the `--serve` flag also consumed it twice, so `remove-boot --serve` reported removing
  one block after removing two.
- and then the test bed showed the guard itself was broken, which no amount of re-reading had:
  **two RubyClaw processes were polling the same token for a quarter of an hour**, seventy-five
  `Conflict: terminated by other getUpdates request` lines in the log and the user's chat
  half-working, while the pidfile named only one of them. Three separate faults, in the order they
  were found: the claim was written *after* the bot connected, and connecting takes about fifteen
  seconds on this board, so any second start inside that window saw nothing running and started its
  own poller; `O_EXCL` on the claim was still not enough, because the file is briefly visible and
  empty, an empty pidfile reads as "no pid", and the other keeper cleared it as debris and claimed
  too; and release deleted the file unconditionally, so the older instance exiting removed the live
  instance's claim and left the next keeper free to start a third poller. The claim is now written
  to a private file and `link()`ed into place before the slow work, a dead pid in it is still taken
  over so a crashed bot does not block its own replacement, and only the process the claim names may
  remove it. Verified on the board: three keepers fired together produce one bot, two of them
  printing `already running`, zero conflicts.
- and the one that mattered most for "leave it running": a **parked service with a dead bot is not a
  running service**. Left alone on the test bed, the bot thread died (`telegram stopped:
  Net::OpenTimeout`, a TLS handshake starved by load on one core), the process sat parked, and the
  keeper's "already running" check would have gone on answering yes forever -- the chat was silently
  dead and nothing said so. The poll loop gives up after six consecutive failures, which is a fine
  design only if giving up is visible, so the parked loop now watches the bot thread and exits
  non-zero. Verified the way it matters: `kill -9` on the live bot with nobody logged in, and cron's
  keeper had it back **121 seconds** later, answering a message.

**picoclaw, on the same board, had never run at all.** Its unit was written for a different machine
(`User=pi`, `/home/pi/.picoclaw`, an `EnvironmentFile` under `/etc/picoclaw/` that does not exist),
so it failed 24,758 times at five-second intervals. Removed at the operator's request; the tree and the
binary were left in place.

## Review round 2 (0.06): the new subsystems

Five reviewers, each with a different brief (concurrency and lifecycle; the scheduler; the tool-call
boundary; the tests and the release path; the docs against the code), all with the instruction to
demonstrate a finding or drop it. Everything below was reproduced before it was fixed, and each fix
carries a test.

**The one that mattered most — a due job ran twice.** The in-process scheduler beside `claw up` and
the cron tick are *both* live on purpose, so two schedulers read the store in the same instant and
both saw the same job as due. Ownership is now taken under the store lock, before the command runs,
and `next_run` is computed from the moment the run *finished* — which also stops a job that outlives
its own interval from being started again while it is still going. Measured before: two concurrent
ticks, two executions. Measured after: two ticks, one execution.

**A typo could cost the whole shell session.** `term`'s command went straight down the shell's
stdin, so an unterminated quote swallowed everything after it — including the marker line that says
the command is done. The call burned its entire deadline and came back empty, and the session
(cwd, exports) died with it. Commands now go through a file the shell *sources*, which contains a
syntax error to that one command; the error is reported, the session survives. `MAX_BYTES` was also
declared and never read, so a runaway command grew memory until its deadline: output is capped now,
keeping the head and the tail (the marker is in the tail) and saying how much it dropped.

**One conversation could be shown another's output.** Two readers on one pipe pair hand each other
the wrong bytes: measured, one caller got back an empty string while its text sat in the other's
buffer. Same class of bug in the browser, one socket instead of one pipe. Both are serialised now.

**A deadline that did not stop the work.** `stop!` signalled the browser and forgot it: the pid was
dropped without waiting, so the next start could find the old process still holding the profile's
`SingletonLock`, and a CDP error path left a chromium running with no handle on it. It now waits for
the process to go (bounded), reaps it, and kills the group on the error path. `at_exit` handlers were
registered per *restart* rather than per object.

**Stale state across a reboot.** The CDP endpoint is read out of chromium's own log; the log was read
whole, so after a reboot the first match was the *previous* run's URL and every call went to a port
nothing was listening on. The log is truncated at spawn (Ruby opens a filename passed to
`out:`/`err:` with `O_TRUNC`) and there is a test that poisons the log first.

**Scheduler defects, each measured.** A `daily 07:30` job ran at 08:30 for half the year (a fixed
86 400 s step across a clock change). An interval of `0` was permanently due, holding a slot on every
tick forever. One unparseable timestamp in the store made *every* enabled job due at once. Valid JSON
of the wrong shape (`[]`, `null`) raised a bare `TypeError` from inside the daemon and stopped all
scheduled work. A `BEGIN` marker with no `END` deleted every line after it — the user's own jobs —
and the README claimed a byte-for-byte restore that was not true, because blank lines between a
user's entries were dropped. `install-boot --every 0` wrote `*/0 * * * *`; `--every 90` wrote a line
that never fires; a path with a space in it split into two words. `crontab -l`'s "no crontab for
user" notice was written back as a job line. A bad timestamp crashed `claw schedule list` mid-output.
The store was renamed into place without an fsync, and stale `.tmp` files were never cleaned up.

**`deliver: telegram` could never have worked.** `notify` asked for `target_chats`; the method was
still called `encrypted_chats`. Every Telegram delivery raised `NoMethodError`, which `deliver`'s own
rescue wrote into the *job log* — where a working job and a broken one look identical. There is now a
test that drives a real POST at a socket.

**The harness could be killed by its own tool.** A tool calling `exit 9` ended the process with
status 9, mid-conversation, telling the model nothing. The registry contains `SystemExit` at the tool
boundary and returns an error string instead. Two smaller boundary bugs: the `grep` builtin passed a
model's pattern through as an option (`--version` printed grep's banner; `--pre=cat` was an
unrecognized option) and now passes `--` first; the `term` timeout had no upper bound, so a model
asking for 60000 "seconds" held the call for 16 hours — clamped to 1–600.

**A test could hold the machine's real credential.** `CLAW_NO_DOTENV` stopped the *project's* `.env`
being read but not the fallback that borrows Hermes's own key from `~/.hermes/.env`, so an in-process
assertion that failed while comparing keys printed the real one into the failure message. The guard
now covers that path too (measured: 35-char key before, empty after).

**Two bugs the fixes themselves introduced, caught by the shipped-copy check.** Sweeping stale
`*.tmp` files when the store is opened deleted a *live* sibling's temp file between its write and its
rename: with six concurrent writers, three jobs vanished (reproduced 2 runs in 3 in a fresh
extraction; the in-repo suite passed, which is why the release check matters). The sweep now only
touches files older than five minutes. The same pattern in `term`'s script directory got the same
guard. And the first version of the crontab-quoting test installed a real cron block into the
developer's own crontab — the leak this suite is otherwise careful to prevent. It was repaired
immediately, the test asserts on the block text instead, the write path is tested through a stub
`crontab` in a sandbox, and `CLAW_NO_CRONTAB` makes an in-process write impossible.

**Test hygiene.** The suite had one real lint offense (`Lint/AmbiguousBlockAssociation` in a new
test), which is why `rake lint` is a gate and not a suggestion. `term`'s tests were writing command
files into the project they were testing; the script directory is now a constructor argument.

### Open after this round

- **One shell and one browser per process** (round 1, item 9): the mutex makes concurrent use
  *correct* — no crossed output — but two conversations still share one `cd` and one page. Fixing
  that needs a conversation context reaching the tool layer.
- **Cron granularity is five minutes** and **the browser needs Chromium installed** (items 10–11).
- Round 1's remaining items stand: installer trust, no CI, no coverage measurement, 32-bit ARM
  untested, the in-process child-trust limit of the self-write pipeline, format duplication.

## Round 4: updating itself (0.10)

`claw update` compares this instance against the upstream it came from and takes what upstream
changed **except on paths this instance has itself changed** — the tool it wrote, the core patch it
applied. Those are conflicts: kept, and named in the report. Eight tests over real git repositories
(an upstream that is a copy of this harness, a clone that writes its own tool) cover the four kinds
of change, the conflict rule, `--check` writing nothing, the dirty-tree rail, and a tree that is not
a clone — including a launcher-initialised archive that carries a remote but no upstream history.

Open, and named rather than solved:

13. **Nothing verifies what upstream sent — medium.** The fetch is HTTPS over the public repo, so the
    transport is authenticated, but there is no checksum or signature on the content and no pinning:
    whoever controls the upstream repository controls what an updating instance runs. That is the
    nature of a self-updating program, and it is the reason the update path is a CLI and scheduler
    command and *not* a tool the model can call — an agent must not be able to reach out and change
    the program it is running inside. Anyone running this in anger should point `CLAW_UPSTREAM` at a
    mirror they trust.
14. **An update whose core change breaks the boot has not been *proven* to auto-revert — medium.**
    The boot-failure revert exists for self-writes, and an update is an ordinary commit so
    `claw rollback` reverses it, but the automatic path has only been exercised for self-writes.
    Untested here, so it is not claimed.
15. **Five real failures on the Pi Zero — found, diagnosed and fixed.** Correcting an earlier entry
    here that blamed contention: two separate runs on the board failed the *same five* tests, with the
    same assertions, so this is not a load artifact and the earlier explanation was wrong. All five are
    now fixed and the board that reproduced them runs the suite green; the serious one by replacing the
    pid-file claim with an exclusive `flock()` taken before anything slow loads. The diagnosis below is
    kept, because it is why the fix looks the way it does. They split into two kinds.

    A test that is not hermetic: `test_a_telegram_delivery_really_posts_to_the_bot_api` expects the
    log line `/telegram: 42/`, but on a machine whose `.env` carries a real allowlist it logs
    `telegram: 999999999, 42` — the test reads the machine's own configuration, so it fails wherever
    that machine is the operator's rather than a fixture.

    Three races that only a slow board exposes, all in the thing 0.09 was proudest of:
    `test_two_keepers_firing_together_produce_one_bot` (two keepers both survived: the claim is not
    atomic enough when I/O is slow), `test_telegram_only_stays_up_with_no_stdin_to_read` (a service
    stop arrived as a signal, `exitstatus nil` — the very failure the early `Signal.trap` was meant to
    end), and `test_a_second_keeper_run_refuses_to_start_a_second_poller` (a running bot had not yet
    recorded its pid when the next keeper looked). Whatever the cause, the guarantee is weaker on slow
    hardware than on the Pi 4, and this is the reason that board exists.

16. **One suite at a time on the board — low, still true.** A run that was called
    definitive gave 216 runs / 1200 assertions / **5 failures** / 10 skips, every failure in a test
    that opens a socket, with the board unable to complete a TLS handshake to `api.telegram.org`
    (`Net::OpenTimeout`, repeated) and its bot logging `Conflict: terminated by other getUpdates
    request`. The cause was found rather than assumed: a *second* suite was running on the same
    one-core board at that moment, plus a bot restart from a deploy in flight. One core, 426 MB, a
    fifteen-minute bot connect and a twenty-minute suite do not share. The rule for anyone testing
    this board: one run at a time, keeper cron removed first (the suite's own driver does that), and
    read the load average before believing a failure. The Pi 4 figure (250 runs / 1605 assertions /
    0 failures / 0 skips) is the suite's own; the board is the environment, and it has to be quiet.

## Work state outside the chat (gaps 6, 7, 12)

The chat is context, not the source of truth. `lib/work.rb` adds a fifth durable store beside
`Schedule`, in the same shape and for the same reason: durable state the harness owns belongs in
the harness, not in a transcript that `/new` erases and a second surface never sees. Four files
under `data/` — tasks, an append-only event log, artifacts and approvals — each written through a
temp file and a rename with an `flock` around every read-modify-write, so `claw run`, `claw work`
and the Telegram bot can all touch them at once without corrupting anything. The suite proves it
the only way that counts: six writer processes run at the same instant, and all twelve tasks
survive (without the lock, the last writer wins and the others vanish).

Two decisions worth stating:

- **The transition rule is data, and it refuses.** `ALLOWED` maps each of the eight states to the
  states it may move to, and `set_state` refuses anything not on the list rather than recording
  it. `DONE` and `FAILED` are terminal: the only way back is `reopen`, an explicit act that says
  so in the log. A `QUEUED` task cannot jump straight to `DONE`. Every accepted move, and every
  creation, is one line in `data/events.jsonl`, so a task's whole history is reconstructable from
  the log alone. All 64 (from, to) pairs are tested both as a rule and through the store on disk.
- **An artifact is the work product, not a claim about one.** `register_artifact` stores the id,
  type, title, project, task, creator, location, version and status the gap analysis asked for,
  and refuses a `task_id` that names no task — a link to nothing is worse than no link.

`claw work` is the plain-text view: anything `BLOCKED` or `NEEDS_APPROVAL` first with the reason,
then open work oldest-first, then the artifacts grouped under the task that produced them.
`tools/work.rb` is the one dynamic tool over the same store, deliberately thin.

**Not covered yet, and named rather than implied:**

17. **Nothing prunes or ages out old tasks — medium.** `data/work.json` and `data/events.jsonl`
    grow without bound; a long-lived instance accumulates `DONE` tasks and event lines forever.
    There is no retention rule, no rotation and no compaction. The view already caps what it
    prints, but the files themselves only ever grow.
18. **No migration for a store written by an older version — low.** The stores are read as-is. If
    a later version changes a field or the state set, older records are not upgraded, and nothing
    records which version wrote a file. For now the answer is "fix or delete it", as `Schedule`
    already says of a malformed store.
19. **Notifications were a later stage — now built.** Routing a change to Telegram, and the operator
    view over it, were stage D; both exist now — see "Notifications and the operator view" below.
    The responsibilities, the unified events and the heartbeat
    that this item used to defer *are* now built — see "Responsibilities, unified events and a
    heartbeat" below. (`Work` still decides nothing on its own; the stages above it read and move
    the records.) (The `AUTO`/`ASK`/`BLOCK` policy that makes `NEEDS_APPROVAL` meaningful *is* now
    built too — see "An autonomy policy" below.)
20. **An approval decision still only moves the task; the policy reads it.** `decide_approval`
    records the decision and moves a `NEEDS_APPROVAL` task to `WORKING` (granted) or `BLOCKED`
    (denied); it does not itself run, withhold or retry any action. `lib/policy.rb` is what asks it
    for a granted approval and consumes it. A `request_approval` on a task that is already terminal
    is refused, and a second decision on the same approval is refused — the first stands.
21. **`claw work` is a snapshot, not a live view — low.** It reads the three stores once, so a
    change landing between two reads can show a task and its artifact one step apart. It is a
    text view for a person, not a transaction.

## An autonomy policy (gap 3)

The gap list called this the highest safety value, because it is what makes unattended operation
defensible: without it, "the agent decides" was the whole answer. It is now a file. `policy.yml`
maps an action name to one of four policies — `auto` runs it, `ask` parks a real approval in the
work store and tells the model it is waiting on a person, `block` and `human_only` refuse and name
the rule and the reason in the message. The decision is made in `lib/registry.rb`'s `call`, before
the tool block runs, so a tool cannot be reached around it.

Two properties carry the argument, and both are tested:

- **Default-deny.** An action that matches no rule is `ask`, never `auto`, and a missing, empty or
  unreadable policy file lands on the same default. A rule the operator did not write cannot grant
  autonomy.
- **A grant is consumed by the call that uses it.** `Work.take_grant` finds a granted, unconsumed
  approval for the action and marks it used in the same critical section (under the store lock), so
  two identical calls at the same instant cannot both ride one grant. The test drives held → granted
  → runs once → a third identical call held again, and asserts the third did not run.

The tool -> action mapping is one explicit table (`shell.run`, `files.read`, `files.write`,
`http.get`/`http.send`, `selfwrite.tool/skill/core`, `work.manage`/`work.decide`, …), never inferred
from a tool's prose; `work.decide` is split from the rest of the store so the agent cannot decide its
own approvals. Matching is by action name with globs, first rule wins. Every decision is one line in
`data/events.jsonl` (`policy.auto`, `policy.ask`, `policy.block`, `policy.human_only`,
`policy.granted`, plus `approval.consumed`), so the log reconstructs both what was auto-approved and
what a person authorised. `test/policy_test.rb` exercises the pure decisions, the shipped file's own
contents, and the gate through the real dispatch path in a sandbox (including a model-loop call held
before it wrote a file).

**Not covered, and named rather than implied:**

22. **Matching is by action name, not by argument — inherent, and the real limit — high.** The policy
    cannot tell which file a write touches, what an HTTP body contains, or what a shell command would
    do. `files.delete: ask` therefore does not stop `sh: rm`, and `http.get: auto` will fetch any URL
    including one that exfiltrates a value in its query string. It is a seatbelt over named actions,
    not a jail; the honest control for the shell is `shell.run` itself. Argument inspection would be a
    different, larger design.
23. **A policy whose `default` is `auto` is not audited — low, deliberate.** Only a rule-driven
    `auto` writes a `policy.auto` line, because that is the "auto-approved by rule X" the log exists
    to record; a `default: auto` is an operator opting out of supervising at all. The shipped file is
    default-deny, so every one of its auto decisions is logged.
24. **No rate or cost limit — medium.** Fifty `auto` actions in a row are all allowed; nothing counts
    calls, bytes or money. A runaway loop is bounded only by the model's step ceiling.
25. **A grant is not scoped by time, task or argument — medium.** It waits indefinitely until used,
    authorises the whole action name (any `files.write`, not the file that was pending), and is not
    tied to the task that requested it.
26. **A held action opens its own task — low, deliberate.** An approval must link to a task (stage
    A's rule), so a held action creates a small `approval: <action>` task under project `policy`.
    Stage C's responsibilities will supply the real task instead.
27. **An approval used to be silent — closed, stage D.** It was visible in `claw work` and in
    `data/approvals.json` and nowhere else; no message was sent when one was parked. It now notifies
    (see "Notifications and the operator view" below), with the exact `claw work decide` command in
    the message. What remains open there is named in that section's own list.
28. **`lib/child_ab.rb`'s replay is exempt, by construction — low.** `RubyClaw.call(..., internal:
    true)` skips the gate for the harness's own A/B replay, which replays calls that already
    happened. The model never reaches that keyword; only the harness's own code passes it.

## Responsibilities, unified events and a heartbeat (gaps 1, 9, 8)

A task is one piece of work; a responsibility is the thing that keeps asking for work. `Work`
gained a sixth store, `data/responsibilities.json`, holding an objective, owner, project,
skill, autonomy level, reporting policy and a list of triggers — and `lib/responsibility.rb`
validates and matches them. Each trigger that fires is normalised into one **unified event**
(`lib/event.rb`: `timer`, `file.changed`, `work.state`, `job.finished`, `webhook`), matched to
at most one responsibility, and turned into exactly one durable task under it. The heartbeat
(`lib/heartbeat.rb`) is the pass that does that, then surveys open tasks: a `WAITING`/`BLOCKED`
task whose dependency is satisfied resumes, a stuck one whose retry is due is retried and, past
its retry limit, marked `FAILED` instead of looping, and a task past its deadline (or with a
failed dependency) parks a stage-B approval. It rides the scheduler's tick (`claw up`,
`claw schedd`) or runs alone (`claw heartbeat`).

Two properties carry the argument, and both are tested:

- **One event, one task, however often it is replayed.** The inbox ledger skips re-queueing a
  key it has seen; the binding guarantee is `Work.add_task_once`, which finds an existing task by
  its `event_key` before creating, in the same critical section, so two processes replaying the
  same event at the same instant cannot both create a task. The test drives submit → drain →
  replay-after-handled and asserts the task count stays at one.
- **Most passes make no model call.** The heartbeat constructs no harness and sends no prompt;
  the test configures a stub model endpoint, runs an idle pass, and asserts the endpoint was
  never contacted.

Two decisions worth stating:

- **The event sources are only what the harness can see.** `timer` and `file.changed` are polled
  from a responsibility's triggers (timers use `Schedule`'s date maths and claim-before-fire, the
  way a job slot is claimed); `work.state` and `job.finished` are read back out of
  `data/events.jsonl`, which every store change already writes — so the writers do not have to
  depend on the event layer; `webhook` is a submission seam (`claw event post`), not a listener.
- **The scheduler is gated now.** The stage-B gate sits in the dispatch path, which governs tool
  calls — but `Schedule.execute` ran a shell job's command itself, so an unattended `sh` job
  reached the machine without ever passing the policy. Verified: `run_due`/`run_job` now check
  `shell.run` before executing, and a held job does not run — it is recorded `held`, a `job.held`
  line goes in the event log, and `Policy.check` parks the approval. A `task` job is not held here
  (its tool calls are gated individually) and a person's `claw schedule run` is not held either.

**Not covered, and named rather than implied:**

29. **A scheduled shell job holds under the shipped policy — high, deliberate, disruptive.**
    `shell.run: ask` means an unattended shell job does not run until a person grants the
    approval; the hold now notifies (stage D) and the message carries the command that releases it.
    Landing this closed a real hole (an unattended `sh` job bypassed the
    gate entirely), but it pauses shell jobs by default. A `task` job is unaffected. The honest
    alternatives — `shell.run: auto` (no gate) or a per-job override — are a policy decision
    left to the operator.
30. **The event sources are limited — medium, stage E.** Only timers, files, internal transitions
    and job finishes exist, plus the webhook seam. Email, calendar, GitHub and regulatory feeds
    are stage E (Scout); nothing here claims them. A `webhook` is a CLI/tool submission, not a
    socket, and it is unauthenticated: any local process that can run `claw` can queue an event
    (which can only create a task through a matching responsibility — it cannot run a tool).
31. **No retention or pruning — medium.** `data/work.json`, `events.jsonl`,
    `responsibilities.json` and the pending-events inbox only grow. The inbox's handled ledger is
    capped (1000 keys, after which a very old replay is caught only by the task's `event_key`),
    but tasks, events and the log itself have no rotation or compaction. `data/` is gitignored, so
    this is disk use, not repository weight.
32. **No cross-process heartbeat lock beyond the flock discipline — low.** Each store write takes
    the one `flock`, and `add_task_once` / `record_retry` do their read-modify-write inside it, so
    two heartbeats (a cron tick and the in-process thread, both live on purpose) cannot corrupt a
    store or double a task. They can still both *read* the same task and both call `record_retry`,
    which would bump `attempts` twice in one pass — the bound is reached sooner, nothing is
    corrupted. A dedicated heartbeat lock would remove even that; it is not here.
33. **A responsibility's reporting is enforced; its autonomy still is not — medium.** `reporting`
    (`on_change`/`on_completion`/`on_failure`/`always`/`daily_digest`/`silent`/`never`) now routes
    what the harness tells a person — see "Notifications and the operator view" below. `autonomy`
    (`auto`/`ask`) is still stored and displayed but does not change what the harness will do on its
    own: execution is decided per action by `policy.yml`, deliberately, because a per-action
    decision is the one that can be reasoned about before it runs.
34. **A responsibility's own task does not fire a `work.state` trigger — deliberate guard.** A
    task created from an event is skipped when the log is scanned for `work.state`, so a
    responsibility watching `DONE` that also produced the task does not create a new task every
    time one finishes. The cost is that chaining off a responsibility's own tasks is not possible;
    the loop it prevents is worse.
35. **A new timer is due immediately — deliberate.** Like `Schedule.add`, a timer trigger's first
    slot is now, so a new responsibility proves itself on the next heartbeat rather than waiting a
    day. A `file.changed` trigger is the opposite: its first poll records a baseline and does not
    fire, so adding one over an existing file does not fire at once.
36. **The scan is O(log size) per pass — low.** The heartbeat reads the whole event log each pass
    to find transitions since its watermark (kept by raw line number). Fine at the sizes this
    runs at; a compacted or indexed log would be the fix if it ever isn't.
37. **The real-state guard covers records, not scratch dirs — low.** `test_helper` fails the run if
    `data/work.json`, `data/events.jsonl`, `data/approvals.json`, `data/artifacts.json`,
    `data/responsibilities.json`, `data/pending-events.json`, `data/notifications.json`,
    `data/heartbeat.json` or `data/telegram.offset` changes.
    `data/term`, `data/browser` and `data/screenshots` are working directories the harness reuses
    and that a run may write; they are not records and are not guarded. The two leaks that were
    found and closed were records — a policy audit line (`claw selftest`'s real `http` call wrote
    the project's `data/events.jsonl`) and the Telegram poll offset. `Policy.audit` now skips a
    selftest (the `CLAW_SELFTEST` rule `SelfWrite` and `Update` already keep), and `Telegram`'s
    offset honors `CLAW_TELEGRAM_OFFSET`.
38. **The leak check fires when the run ends, not at the moment of the write — low.** The
    `after_run` hook (and `test/real_state_test.rb` when it runs first) names the store that
    changed and fails the run; it does not abort the test that wrote it, because that would need a
    write interposer in the store layer. Failing the run and naming the store is the point.

## Notifications and the operator view (gaps 13, 14)

The harness says when it needs a person, through the delivery path it already had. `lib/notify.rb`
runs as the heartbeat's last step — so it costs nothing new to install, and a pass still makes no
model call — reading the event log the stores already write, turning a parked approval, a
`DONE`/`FAILED`/`BLOCKED` transition and a held job into one short message, and sending it to the
bot's allowlisted chat. `claw status` is the terminal-shaped answer to the same question: what waits
on you (with the exact command), what runs, what failed and why, what is stale, and the harness's
own vitals.

Four properties carry the argument, and each is tested:

- **Routing is real, not recorded.** A notification about a responsibility's work is checked
  against that responsibility's `reporting` policy (`Responsibility::REPORTING` — one list,
  enforced where a responsibility is created and again at the point of sending). A `silent`
  responsibility's blocked task sends nothing; an `always` one's does. Before this stage the value
  was stored, displayed, and ignored.
- **Only an allowlisted chat, ever.** No allowlist means no destination: the notification is
  recorded undeliverable and nothing is sent. A chat that is not listed is refused — `claw notify
  test --chat 999` proves it. The bot's default-deny rule is the notification rule.
- **One condition, one message.** Dedup is a durable keyed ledger in `data/notifications.json` (an
  approval id; a task and the state it reached), not a timestamp comparison. Two heartbeat passes
  back to back send exactly one message for one pending approval, and a task that fails on its
  third attempt sends one message, not three — `task.retries_exhausted` and the `task.state FAILED`
  line it follows share a key.
- **A failed send is queued, not lost.** The message waits in `data/notifications.json` under the
  same `flock` and atomic write as every other store, and the next pass retries it. The test fails
  the first send against the stub Bot API and delivers the message from a *second process*, so the
  restart path is covered as well as the retry. With no token at all the harness runs headless: the
  send fails into the queue and the pass reports it.

Decisions a reader might disagree with, stated rather than buried:

- **A move to `NEEDS_APPROVAL` is deliberately not its own notification.** Every approval already
  writes `approval.requested`, so notifying on the state move too would double every approval. A
  task moved to `NEEDS_APPROVAL` by hand (`claw work state <id> needs_approval`) therefore does not
  notify, because there is no approval behind it for a person to act on.
- **`daily_digest` withholds rather than bundles.** There is no scheduled daily summary yet: the
  policy records the item in a capped digest tally that `claw status` shows, and sends nothing.
  Calling it "daily" and sending per-pass would be exactly the kind of claim the gap analysis warns
  against.
- **A completion notifies by default.** `on_completion` is the default for a task with no
  responsibility, so a hand-made task reaching `DONE` announces itself. That is the recorded default
  doing its job; `on_failure` is the quieter choice and `silent` the quietest.
- **The queue is capped at 500 and drops the oldest past that.** An unbounded queue of undelivered
  messages on a machine whose token was removed is a disk problem, not a safety net. The drop is
  counted and reported.
- **Notifications are observed from the event log, not emitted by the writers.** `Work` does not
  learn about `Notify`; the scan reads what the stores already write, with a line-count watermark
  and the seen ledger. The cost is that a hand-edited log can *suppress* a notification (a key
  already seen) but cannot forge a send.

**Not covered, and named rather than implied:**

39. **Telegram only — medium, by design of the stage.** No email, no SMS, no push, no webhook
    receiver, and no fallback channel when Telegram is unreachable. The seam is `Notify.attempt`
    (one method, one destination list), so a second channel is a real piece of work rather than a
    config flag.
40. **The queue is local state — medium.** It lives in `data/`, which is gitignored and backed up
    only by whatever the machine's own snapshot job does. Wiping `data/` loses undelivered
    notifications. There is no acknowledgement either: "sent" means the Bot API accepted the
    message, not that anyone read it.
41. **The dedupe ledger forgets (1000 keys, capped) — low.** After a thousand notifications a much
    older condition, replayed, could notify again. Like the event inbox, the cap bounds growth
    rather than guaranteeing correctness; the keys are conditions rather than events, so the
    practical window is long.
42. **`claw status` shells out to `df` and reads `crontab -l` — low.** Disk pressure is the honest
    number from the system tool (no gem is available and Ruby has no `statfs`), and "cron installed"
    is a crontab read. Both degrade to "unknown" rather than guessing, and both only read.
43. **The view is a snapshot and can be raced — low.** `claw status` reads the stores without
    holding the one lock across the whole render, so a pass writing between two reads can make one
    line disagree with another. Each individual read is atomic, so nothing is half-read; a strictly
    consistent view would need the lock, which would block the heartbeat behind a terminal.
44. **One inbox, no per-chat routing — low.** Every allowlisted chat receives every notification;
    there is no notion of an owner's chat. A responsibility's `owner` is recorded but is not used
    as a destination.

## Scout, read-only (gap 2)

Two tools and one rule. `scout_search` is a keyless web search returning titles, URLs and snippets;
`scout_read` fetches one http(s) URL and returns its readable text, HTML stripped with the standard
library. The rule is that Scout reads and never writes, and it is a property of the code rather than
of this document: `lib/scout.rb` has a single outbound path (`http_get` → `one_get`), which builds a
single kind of request (`Net::HTTP::Get`), guarded by a one-entry verb table
(`REQUESTS = {"GET" => Net::HTTP::Get}`) that `guard_method!` checks before a socket opens. The
policy names two actions, `scout.search` and `scout.read`, both `auto`, and there is no writable
Scout action name at all — a POST from Scout is not `ask`, it does not exist, so no rule, no grant
and no future edit of the rule file can reach one. Tests assert the code path (the verb table, the
action mapping and its absence of a third name, a source scan of the file, and a local server
recording the method of every request Scout sent) rather than the claim.

**How it got here.** DuckDuckGo's html endpoint — the route the plan names — was tried first and
verified from this machine before anything was built on it. With a browser User-Agent it answered
once with ten results; within a minute it returned its anti-bot page (HTTP 202, zero
`result__a` markers) and it has kept doing so since, with a browser UA, a bot UA, a curl UA and an
empty one. Under an honest non-browser User-Agent it returns that page immediately. So the endpoint
is implemented as the first provider and the fallback is the route that actually works here:
**Wiby** (`https://wiby.me/`), keyless, GET, robots-clean, which answers this machine with real
results under an honest User-Agent. Bing's HTML search was checked too and returns real results, and
was **rejected on principle**: its `robots.txt` disallows `/search` for `User-agent: *`, and a tool
that honours robots.txt for a page fetch but ignores it for a search would be picking the rule it
likes. Marginalia's v2 API (keyless with the `public` key) and a sweep of 83 public SearXNG
instances were also probed; all were rate-limited, captcha-gated or unreachable from here. A search
tries its providers in order and, when none answers, reports what each one said — "no results" and
"every route failed" are different facts.

**What is implemented, precisely.** GET only. An honest User-Agent
(`rubyclaw-scout/0.1 (+read-only research; RubyClaw agent harness)`) — deliberately not a browser's,
so an engine that refuses non-browser agents is refused rather than fooled. A minimum interval
between outbound requests (1.5 s) and a per-run cap on them (20), both env- and
`Scout.reset!`-overridable, counted at the moment of issue including robots.txt fetches and redirect
hops; past the cap the answer is a clear error, never a partial result. Timeouts of 10 s to connect
and 20 s to read, plus a whole-read deadline, sized for this board's intermittent outbound TLS. A
200 KB byte cap on the body, streamed and abandoned at the cap so the transfer stops rather than
being read and discarded. A 20,000-character cap on extracted text and a 6 KB cap on what is handed
to the model, so the untrusted-content markers survive `lib/boot.rb`'s own 8,000-byte tool-result
cap instead of being cut off with the content. Redirects followed at most four times, http(s) only.
`robots.txt` consulted for `scout_read`, cached per host for the run, with an unreadable robots.txt
meaning no access (RFC 9309's "unavailable") and a 4xx meaning "none published, allowed". A
non-200, a redirect loop, a capped read and a robots refusal are each an error that says what
happened.

The untrusted-content boundary is stated in three places the model reads: the returned text is
wrapped in `BEGIN/END UNTRUSTED CONTENT` markers carrying the rule; both tool descriptions carry it;
and `lib/harness.rb`'s system prompt carries it for every fetched source, not only Scout's.

The trigger half rides what already exists. A responsibility can carry `scout <query>`, polled by
the heartbeat on its own interval (6h by default, claim-before-run under the store lock with the
search itself outside the lock), each unseen page becoming a `scout` event keyed on the trigger and
a fingerprint of the URL. The event creates exactly one task under the responsibility — its detail
carries the finding's title and URL — and the notification scan routes that task's completion
through the responsibility's recorded `reporting` policy. **No notification code was added.** A poll
that fails is recorded and retried in 15 minutes rather than waiting out the interval.

## Confirmed sound

The frozen tool surface (seven builtins, growth appended so the prompt prefix stays
cacheable and the model's inventory never silently changes); the replay evidence for
consolidation (evidence computed locally, model consulted only when things cluster, and
no model call at all when they don't); the secrets discipline (`.env` 0600 and gitignored,
`config.yml` never holding a key, the zip shipping a pristine copy; when this became a public release it stopped being tracked at all, since a committed config.yml is one machine's endpoint rather than the project's);
the entry point's honesty about what it cannot install (no armhf build exists upstream);
default-deny Telegram; the 4,000-character caps on injected notes.

## Open

1. **Installer trust — medium.** `./rubyclaw` downloads the Ruby tarball over TLS from
   `github.com/ruby/ruby-builder` and relocates it; it does not verify a published
   checksum or signature. Upstream publishes none, so doing this properly means pinning a
   hash per asset and updating it per release. It never uses sudo and never runs a
   remote script — but a compromised mirror or TLS break would be executed.
2. **Format duplication — low.** The tool list, the usage table and the model line are
   built three times (`bin/claw`, `lib/chat.rb`, `lib/telegram.rb`) and have already
   drifted (the CLI showed 20 evolution entries where chat showed 10). One
   `RubyClaw::Commands` formatter would fix it.
3. **Metrics backlist — low, advisory.** `rake lint:metrics` reports 18 items across six
   files; the largest is `lib/chat.rb#dispatch` (63 lines, cyclomatic 32). The enforced
   gate (`rake lint`) is clean and is what CI should run.
4. **No CI — low.** The gate runs locally; nothing enforces it on push. A workflow file
   would be a few lines, and no test would need to change.
5. **The child-process trust limit — inherent, documented.** A proposal is executed in the
   same process as the tool it is compared against, so it can still make the replayed
   call look right (in the merge case: answer the recorded arguments by delegating to the
   original). Scoring in the parent and checking the inventory close the cheap routes; a
   harness that runs model-written code in-process cannot verify semantics it does not
   define. The stronger design is out-of-band — a jail (namespaces or bubblewrap) plus
   inputs the proposal has never seen.
6. **32-bit ARM is "should work", not tested — medium.** No armhf hardware or emulator
   here. The suite passes on Ruby 3.4.11 and 3.2.11; `./rubyclaw selftest` on a Pi Zero
   is the run that would settle it.
7. **Test-fake fidelity — low.** `FakeTG` does not model per-update offset bookkeeping
   and `FakeLLM` does not record every request path (`/models`, or a call given a raw
   body), so no test can yet assert "the harness made no request at all" in those cases.
8. **No coverage measurement — low.** The tests are behavioural; nothing reports line
   coverage, so "is this file tested?" is a judgement call rather than a number.
9. **One shell and one browser are shared by every conversation — medium.** `term` and `browser`
   keep process-wide sessions, so under `claw up` a Telegram chat and the local prompt are typing
   into the same shell and looking at the same page. The fix is real plumbing (a conversation
   context reaching the tool layer) rather than a local patch, so it is named here instead of
   half-done.
10. **Browser needs Chromium installed — low, documented.** Nothing is bundled and nothing is
    installed for you: `browser` reports that it cannot find a binary and tells you what to
    install. Screenshots and the profile also grow without bound (`data/browser/` is hundreds of
    megabytes of cache) — nothing prunes them yet.
11. **Cron granularity is five minutes — low.** A job due at 07:30 may run at 07:32 if the
    in-process scheduler is not up, because that is how often `schedd --once` runs. Fine for
    reports and checks; not a timer.
12. **Daylight saving — low, documented.** `daily 07:30` is local wall-clock time. On the spring-
    forward morning there is no 07:30 to run at, and Ruby's `Time.local` normalises it forward, so
    the job runs on the shifted clock rather than not at all.
13. **Prompt injection is mitigated, not prevented — high, inherent.** Scout tells the model, in the
    tool result, in the tool descriptions and in the system prompt, that fetched content is data and
    that instructions inside it are an attack. That is a warning, not a boundary: the model is the
    component being warned, and a well-crafted page can still persuade it. The structural mitigations
    are that Scout cannot write anything (so an injected instruction cannot make Scout act), that
    every write it might be talked into goes through the policy gate, and that the tasks a finding
    creates go to a person. The honest limit: fetched text enters the same context as the
    instructions, and nothing here can separate them. A stronger design quarantines fetched content
    behind a summarising pass that never sees the operator's instructions.
14. **Search results are whatever the engine returns — medium.** No quality control, ranking,
    spam or bias mitigation, deduplication across providers, or freshness filter. The fallback index
    (Wiby) is a small-web index: for many queries its results are marginal or unrelated, as its own
    fixture shows. Scout reports what the engine said and does not judge it, and a model that treats
    thin results as evidence is the failure mode — nothing in the code stops that.
15. **No caching and no archival — medium.** Every read refetches, and a heartbeat poll re-searches
    on every interval, so repeated research costs repeated requests to other people's servers. Worse,
    nothing records *what a page said when it was read*: the task's detail keeps the URL, but if the
    page changes or disappears, the text that informed a decision is gone from the store (the
    transcript is not durable evidence). Citations in Scout's output are therefore "a page at this
    URL said something", not an archived quote.
16. **The DuckDuckGo provider is fixture-tested only — low.** The parser for its html endpoint is
    exercised against that endpoint's markup shape in a local fixture, never live, because from this
    machine the endpoint answers with its anti-bot page. If it changes its markup (or the block
    lifts), the parser needs one real page to confirm it. The live smoke test in the suite exercises
    whichever provider does answer — here, Wiby.
17. **robots.txt matching is an approximation — low.** Longest matching pattern wins, `*` and `$`
    are supported, and `Allow` beats `Disallow` on a tie; patterns are compared by length rather
    than by RFC 9309's exact specificity rule, user-agent groups are matched on a substring, and
    `Crawl-delay` is ignored (the minimum interval is a fixed 1.5 s for every host). It is a good
    citizen, not a certified crawler. `scout_search` does not consult robots.txt at all, which is a
    deliberate, recorded decision (a search query is a request to an engine, not a crawl; and every
    engine disallows `/search`, so the alternative is having no search) — but it is a departure, and
    it is named here rather than buried.
18. **A scout poll happens inside a heartbeat pass — low.** A due scout trigger searches the web
    during the pass, so a slow or hanging provider delays that pass by up to the search timeouts
    (~25 s) — bounded, and the search runs outside the store lock so other writers are not blocked,
    but the heartbeat is not otherwise protected from a slow web. A separate worker, or a queue the
    pass only enqueues into, would decouple the two.

## Round 5: the gaps closed, and what a live run of the whole loop exposed (0.0.1-alpha)

Renumbered to 0.0.1-alpha before the first public push. This is the first release anyone outside this
machine will see, so it starts from 0.0.1 rather than continuing an internal count; earlier rounds keep
the numbers they were written under.

Stages A-E of the gap plan landed and were each verified independently at their own commit: operational
state outside the chat, an autonomy policy enforced before anything runs, responsibilities with a unified
event layer and a heartbeat, notifications the harness originates itself, and a read-only Scout. One
end-to-end run was performed by hand in a sandbox copy of the tree, and it produced two things worth
writing down rather than smoothing over.

1. **A grant is scoped by action name, not by the action.** Observed live: a scheduled job's `shell.run`
   was held by policy and granted, and the *next* scheduled job -- a different command, written later --
   consumed that grant and ran, leaving the original job held on its next due time. This is the
   consequence of item 25 rather than a new defect, but it is the one a reader is most likely to be
   surprised by: granting one shell command authorises the next shell command, whoever asked for it.
   Until a grant carries the arguments it was granted for, treat granting a shell run as granting a
   shell run.
2. **A task can be left WORKING with nothing running it.** The task created for the held job stayed
   WORKING after its grant was consumed by the other job. Nothing reconciles a task that believes it is
   running but is not; the deadline marker in the operator view is what surfaces it today.

Also observed: the suite's assertion count moves by one with the test seed (2504 and 2505 on the same
tree), so every "N assertions" figure in the README is that particular run's, not a constant.

## Known flakiness

**The suite is not deterministic.** One full run of the same tree has produced failures
that a later run of identical code did not reproduce (376 runs, 0 failures). The failing
run's log was overwritten before its failures were named, so the test responsible is not
yet identified; the seed of each run is printed in its output, and future runs should be
kept rather than overwritten. Until this is reproduced and pinned, treat a single red run
as a signal to re-run and capture, not as proof of a defect — and a single green run as
weaker evidence than it looks.
