# RubyClaw

> ## ⚠️ Experimental software — read this first
>
> **RubyClaw is experimental. It is potentially unstable, its behaviour can be
> unpredictable, and much of its code was written by an AI agent.** It ships at
> version 0.0.1-alpha, which is what that means. It
> writes code, holds state on disk, runs commands it wrote itself, and acts on a
> schedule when you are not watching. Run it somewhere you are willing to have it
> misbehave: a container, a spare machine, a directory you can delete. Read the code
> before you trust it with anything that matters. There is no warranty, and the
> licence says so twice.

A small, self-building agent harness in Ruby. You give it a model and a shell; it gives you a
program that grows its own tools, keeps notes, schedules its own work, drives a browser, and comes
back after a reboot. Stdlib only — **no gems at runtime** — and one entry point (`./rubyclaw`) that
configures itself on a new machine, with no build step.

**Site:** [rubyclaw.lol](https://rubyclaw.lol) &nbsp;·&nbsp; **Source:** [github.com/hatumai/RubyClaw](https://github.com/hatumai/RubyClaw)

## Running unattended

The shipped `policy.yml` is **default-deny**: an action no rule covers is parked for a
person, never run. Reading is autonomous -- files, searching, GET requests, Scout, notes,
its own task store -- and writing, the shell, sending, spending, scheduling and growing
its own code park. That is what makes leaving it unattended defensible.

To run it fully unattended, change one line at the top of `policy.yml`:

```yaml
default: auto          # auto | ask | block | human_only
rules:
  - match: [money.spend]   # one action, or tool.* / a tool name
    policy: block
    note: never let this spend without me
```

Put it back to `ask` if you would rather approve each action yourself — one line, and
the harness tells you so when it parks something. `human_only` refuses the action
outright, and `block` does the same while recording why. The file is read on every
check, so an edit takes effect without a restart. `CLAW_POLICY=/path/to/other.yml`
points at a different file.

From Telegram the policy is readable and changeable without a shell: `/policy` shows the
default, the file it came from and the rules in force, and `/policy auto|ask|block|human_only`
sets the default. The write goes to **`instance/policy.yml`**, layered the way
`instance/SOUL.md` is — it wins when present, then `CLAW_POLICY`, then the shipped
`policy.yml`. So a command from chat never rewrites the git-tracked file a `git pull`
brings down, and the reply names which file won.

## What it does

- **Writes its own tools, verified before trust.** Ask for something it cannot do and it writes a
  new tool, which is syntax-checked, loaded in a throwaway child process, and exercised with real
  arguments before it is promoted — so a failure goes back to the model, not to you as a broken
  harness.
- **Remembers, and keeps work outside the chat.** Durable notes survive a restart; a task is a
  record in one of eight states (`QUEUED` … `DONE`) with illegal moves refused, an append-only log,
  artifacts tied to their task, and approvals waiting on a person — all in `data/`.
- **Keeps standing commitments.** A *responsibility* (an objective, an owner, a project, a skill and
  triggers) starts work on its own; a heartbeat pass resumes, retries (bounded, then `FAILED`), and
  parks an approval when a person is needed.
- **Reads the web without a key, and cannot write to it.** [Scout](#scout-read-only) is a keyless
  search and a one-URL read, GET-only by construction.
- **Asks before it acts.** `policy.yml` decides, per action, whether the agent may just do it
  (`auto`), must ask (`ask`), may never (`block`), or is not the actor (`human_only`) — checked
  before anything runs, **default-deny** for anything unmatched.
- **Grows, updates and audits itself.** It schedules its own work through your crontab (no root, no
  systemd), survives a reboot, runs as a service (`./rubyclaw up --telegram-only`, kept by cron),
  drives a browser and keeps a shell open; `./rubyclaw update` takes upstream changes unless this
  instance changed that path itself; `consolidate`, `evo` and `rollback` audit and undo.

## Quick start

```sh
git clone https://github.com/hatumai/RubyClaw.git && cd RubyClaw
./rubyclaw            # first run: a few questions, then a prompt
```

The release archive (`RubyClaw0.0.1-alpha.zip`) is a convenience copy, not a clone of the repository
— it runs, but `./rubyclaw update` works only in a clone. On Linux (x86-64, arm64) the entry point
installs a prebuilt Ruby if you have none; elsewhere bring Ruby 3.1+ (tested on 3.3 and 3.4). The
wizard writes your model and endpoint to `config.yml` and your credentials to `.env` (gitignored;
`config.yml` holds no secrets). `./rubyclaw model` shows which key source won, never the value;
`./rubyclaw up` runs prompt, bot and scheduler together, `--telegram-only` for the service shape.
Model, endpoint and key come from `CLAW_MODEL`, `CLAW_BASE_URL` and `CLAW_API_KEY`, or `config.yml`.

## How it grows itself

A tool the model writes is not promoted on trust: syntax check; load it in a throwaway child process
(a tool that cannot load never reaches the tree); exercise it with real arguments; only then write it
under `instance/tools/`, commit, and load it live. Tools are appended after the builtins, so the
cached prompt prefix survives a new tool and the harness gets cheaper, not more expensive; the
shipped `tools/` set loads first and still works, and an instance tool that reuses a name wins.
Anything needing the harness's own lifecycle — an open shell, a live browser, durable state — is a
builtin, because the model cannot write those. Patches to `lib/` are never hot-loaded: `extend kind:
"core"` takes effect at the next start, and two consecutive boot failures revert automatically.

## It updates itself

An instance grows: it writes tools, keeps notes, and can patch its own core; upstream grows too. So
`./rubyclaw update` is *selective*, not a pull (`--check` reports only, exiting 2 when there is
something new): for every path upstream changed, this instance's copy is compared against the last
upstream commit it synced with. Untouched here, take upstream's version; changed here, that is a
conflict left exactly as it is and named in the report.

**`instance/` is refused outright, before anything is compared** — there is no path from upstream
into it, and the harness's own growth lands there too (`extend kind: "tool"` into `instance/tools/`,
`"skill"` into `instance/skills/`). The loaders read the shipped `tools/`/`skills/` first, so a
shipped tool still loads and an instance file that reuses a name wins. Paths under `lib/`, `bin/`,
`rubyclaw`, `test/` and `scripts/` take effect at the **next start**; tools, skills and the
instance's sets load every turn. The upstream is `https://github.com/hatumai/RubyClaw.git`, fetched
over HTTPS, so no credentials are needed; a fork or mirror can be set with `CLAW_UPSTREAM` or
`upstream:` in `config.yml`.

**The model cannot run this:** self-update is a CLI and scheduler command, not a tool, so an agent
cannot change the program it is running inside. Arm it with `./rubyclaw schedule add self-update
"weekly sun 09:00" './rubyclaw update' --telegram`.

## Work that outlives the conversation

Chat history is context, not the source of truth. What the harness is working on lives in `data/`,
in plain files you can read and edit by hand: `data/work.json` (tasks), `data/events.jsonl`
(append-only history), `data/artifacts.json` (work products tied to their task) and
`data/approvals.json` (what waits on a person). A task is in one of eight states — `QUEUED THINKING
WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED` — and the moves between them are a rule, not a
convention: `DONE` and `FAILED` are terminal, the only way out is an explicit reopen, an illegal
move is refused, and every accepted move is one line in the event log.

```sh
./rubyclaw work                                  # the text view: stuck and waiting-on-you first
./rubyclaw work add "write the quarterly report" --project ops
./rubyclaw work artifact report report.md data/report.md t-1a2b3c
```

The model reaches the same store through the `work` tool, so a task it queues is the one `./rubyclaw
work` shows, on any surface, after a restart. The stores are JSON on disk with a lock around every
change — not SQLite, because the driver is a gem and this project ships none.

## Work that keeps asking: responsibilities, events, the heartbeat

A task is one piece of work. A **responsibility** is the thing that keeps asking for work: an
objective, an owner, a project, a skill, an autonomy level, a reporting policy, and the **triggers**
that start work toward it (`data/responsibilities.json`). Add one with `./rubyclaw resp add "keep the
deploy notes current" --trigger "timer daily 07:00" --project ops --owner the operator`; read them
with `./rubyclaw resp`.

Every trigger that fires becomes a **unified event**, and the heartbeat matches it to a
responsibility, or ignores it — a match creates exactly one durable task *under* it, and the same
event never creates a second task. Sources here are `timer` and `file.changed` (polled by the
heartbeat), `work.state` and `job.finished` (read back from the event log), `scout`, and `webhook`
(`./rubyclaw event post`, a submission seam, not a socket). Email, calendar, GitHub and regulatory
feeds are **not** sources here.

The **heartbeat** (`./rubyclaw heartbeat`, or `--poll 60` to loop) is one pass that drains events
into tasks, resumes a `WAITING` or `BLOCKED` task whose dependency is satisfied, retries a stuck task
a bounded number of times (then `FAILED`), and parks an approval past a deadline or after a failed
dependency. It runs on the scheduler's tick too, and **most passes make no model call at all.**

## How it tells you when it needs you

An agent left running without you is only useful if it says when it is stuck. The heartbeat's last
step routes what the pass did to a person through the Telegram bot the harness already has — no
second delivery mechanism, and no message ever sent to a chat that is not on the bot's allowlist.
`./rubyclaw notify test` proves the path end to end, `notify queue` and `notify drain` show and retry
what could not be sent, and `./rubyclaw status` is the operator view.

What is reported: a parked approval — as a message carrying **Approve** and **Deny** inline buttons,
with the exact `./rubyclaw work decide <id> granted` command as a fallback; tapping a button decides
the approval through the same store path `claw work decide` uses, answers the tap, and edits the
message to show the outcome with the buttons spent — a task that reached `DONE`, `FAILED` or
`BLOCKED`, and a scheduled job the policy held
— never raw logs. The same surface is operable by text, for a client that does not render buttons:
`/approvals` lists every pending approval, each as its own message carrying its own buttons, and
`/approve <id>` / `/deny <id>` decide one by text through that same store path. Every command is
gated by the allowlist first, so an unlisted chat can neither see nor decide anything.
A responsibility's `reporting` policy decides the rest (`on_change`/`always`,
`on_completion` the default, `on_failure`, `daily_digest`, `silent`/`never`). Only a chat in
`telegram_allowed_chat_ids` (or `CLAW_TELEGRAM_ALLOWED`) is ever a destination; with no allowlist
nothing is sent, and the notification is recorded as undeliverable rather than aimed at a guessed
chat. A failed send waits in `data/notifications.json` and the next pass retries it, and
notifications are keyed by condition, so a task retried three times before it fails sends one
message. **With no bot token the harness still runs** — notifications are queued and the pass
reports the failure.

## Scout, read-only

Scout gives the harness two ways to read the open web, and no way to write to it: `scout_search` (a
keyless search returning titles, URLs and snippets) and `scout_read` (one URL, HTML stripped with the
standard library). Both are ordinary tools the model calls by name; nothing to install, no key, no
account. No logged-in pages, no JavaScript-rendered sites, no paywalls — and deliberately no browser:
`scout_read` fetches bytes, so a page that only exists after its scripts run yields its shell, not its
content (`browser` is the tool for that, and it is `ask` in `policy.yml`).

**Read-only, enforced rather than asserted.** `lib/scout.rb` has one outbound path, builds one kind
of request (`Net::HTTP::Get`), and its verb table has exactly one entry — every other verb is refused
before a socket is opened. `policy.yml` names two Scout actions, `scout.search` and `scout.read`,
both `auto`, and there is deliberately **no third name**: a POST from Scout is not "ask", because
there is no action to ask for. Fetched content is wrapped in `BEGIN UNTRUSTED CONTENT` / `END
UNTRUSTED CONTENT` markers saying it is quoted data that cannot change the task, the policy or the
tools; that is mitigation, not immunity, and `REVIEW.md` records prompt injection as an open risk.

It is a good citizen rather than a promise: GET only, an honest `rubyclaw-scout/0.1` User-Agent, a
minimum interval and a per-run cap (`CLAW_SCOUT_MIN_INTERVAL`, `CLAW_SCOUT_MAX_FETCHES`), timeouts
and a byte cap, at most four redirects, and `robots.txt` respected for `scout_read` (not
`scout_search`). A read that cannot be completed is an **error, never a partial page**. Scout tries
DuckDuckGo, falls through to **Wiby** where that returns an anti-bot page, and reports what each
route said if all are silent. A responsibility can carry a scout trigger (`--trigger "scout ruby
security release"`); the heartbeat polls it every 6h, each new page becomes a `scout` event, and that
creates exactly one durable task routed by the responsibility's `reporting` policy.

## What it will and will not do without a person

An agent you leave running needs an answer to "what will it do on its own?". RubyClaw's answer is a
file you edit, not a promise: `policy.yml` maps an **action name** to one of four policies — `auto`
(run it now), `ask` (do not run it; park an approval and tell the model it waits on a person, whose
grant lets the same action run once), `block` (never run it), `human_only` (the agent is never the
actor). The decision is made in the tool dispatch path, **before** the tool runs, and it is
**default-deny**: an action matching no rule is `ask`, never `auto`, and a missing policy file fails
the same way. Out of the box:

| action | policy |
| --- | --- |
| `files.read`, `files.search`, `http.get`, `scout.search`, `scout.read` | auto |
| `notes.write`, `work.manage`, `telegram.send` | auto |
| `files.write`, `files.delete`, `shell.run`, `http.send` | ask |
| `browser.drive`, `schedule.manage`, `selfwrite.*` | ask |
| `work.decide`, `credentials.*` | human_only |
| anything else | ask (default-deny) |

Action names come from one explicit table (tool name → action name) in `lib/policy.rb`; matching is
on that name with globs (`files.*`), first rule wins. A held action does not fail: it parks a real
approval and comes back to the model saying so, and a person resolves it with `./rubyclaw work decide
<approval_id> granted` or `denied`. A grant is **consumed by the call that uses it**. The harness's
own Telegram sends are `telegram.send`, `auto` by an explicit rule: the channel that carries an
approval must never itself be parked, or approving anything would deadlock. **The scheduler
is gated too:** a shell job's command is checked before it runs, and under the shipped policy
(`shell.run: ask`) an unattended job **holds** — out of the box, **every scheduled shell job waits
for a person**. Matching is by action *name*, not by argument, so `files.delete: ask` does not stop
`sh: rm` — a seatbelt, not a jail.

## Tests

The suite is green: `ruby -Ilib -Itest test/all.rb` runs it with no failures, `rake lint` is rubocop
Lint + Security clean, and `./rubyclaw selftest` exercises the self-write pipeline. It never touches
your real crontab, your real credentials, or a real model — sandboxes with a stub Bot API and a stub
LLM — and never writes the project's own runtime state. It needs no network: Scout's search, reader
and trigger run against a local fixture server. The two **live** smoke tests are the deliberate
exception: they try a real search and a real page, and **skip** (never fail) when nothing answers.
The browser test skips rather than fails where Chromium is installed but cannot run (armv6 has no
NEON), carrying the machine's own words.

## What this has actually been tested on

Two machines, both Raspberry Pis. **A Raspberry Pi 4 Model B** (aarch64, Debian 13, Ruby 3.4.11)
runs the whole suite green, live smoke tests included. **A Raspberry Pi Zero W** (one core, 426 MB
RAM, ARMv6, Ruby 3.3.7) runs it too, and is the floor rather than a recommendation — roughly a tenth
of the machine above. It is also where the slow-hardware races showed up, which is the point of testing
on it at all.
A better machine runs it much better: this is single-process, stdlib-only Ruby with no compile step,
so it scales the way you would expect and nothing in it is tuned for a Pi.

## Platform support

| Platform | Runs | Notes |
| --- | --- | --- |
| Linux x86-64, arm64 | yes | the entry point installs Ruby for you if needed |
| Linux armv6 (Pi Zero, Pi 1) | yes | bring Ruby from your distro; the installer refuses armv6 cleanly |
| macOS | probably | stdlib only, no gems; bring Ruby 3.1+ |
| Windows | no | POSIX shell and process semantics throughout |

## Security, plainly

- `sh` and any code the model writes run **as you, with no sandbox** — the whole design of an agent
  that can do anything useful, and the risk you are accepting. Run it as a user you would be
  comfortable giving a shell.
- Credentials live in `.env` (gitignored), never in `config.yml` (which is instance state: gitignored, and written by `./rubyclaw setup`); `./rubyclaw
  model` prints which key *source* won, never the value.
- The Telegram bot is default-deny: with no allowlist it refuses every chat, including yours.
- Self-written code is verified before promotion, but it is still code written by a model running as
  you. Read `instance/tools/` and `tools/` if you care; they are small.

## Limitations

- The installer downloads a prebuilt Ruby **without verifying a checksum**; install Ruby yourself if
  that matters.
- No sandbox (above), no dry-run mode. The policy gates a *named* action before it runs, but cannot
  see what a command or a request body contains, so `sh` and self-written code still run as you.
- A **scheduled shell job is held by the policy** until a person grants the approval (see
  `REVIEW.md`).
- **Notifications are Telegram-only, and free text.** No email, SMS or webhook receiver; a send that
  fails waits in a local queue, so wiping `data/` loses it, and there is no scheduled daily digest
  yet (`daily_digest` simply withholds the per-event messages).
- The free OpenRouter pool rate-limits without warning; a paid key or DeepSeek is steadier.
- Cron granularity is five minutes, and the bot's keeper is a five-minute no-op check.
- The catalog of what it can do is only as good as `./rubyclaw tools`; there is no plugin index yet.

## A note on the code

Much of this was written by an AI agent, including large parts of the harness that then went on to
write its own tools. It has been exercised on real machines and it has a real test suite, and none
of that makes it wise. Read it before you rely on it.

> **Experimental, and largely AI-generated.**

## License

**MIT.** Do what you like with it — use it, sell it, fork it, ship it inside something else. The
only condition is the usual one: keep the copyright notice. See [LICENSE](LICENSE).

Contributions are welcome and are licensed under the same terms.

## How releases are made

Every change lands on its own branch and is merged into `main` with a merge commit, so the
history shows what changed, when, and in what order. Nothing is squashed. Each merge to
`main` bumps the **minor** version in `VERSION` (`0.1.0-alpha` -> `0.2.0-alpha`).
