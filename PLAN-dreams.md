# PLAN: Dreams — offline consolidation for RubyClaw

Source: "I asked Meta's Muse for its filesystem and it sent me 6.8 GB" (Peter James, mouse.dev,
2026-09-22), plus the public record of the 2025–2026 "dreaming" family (Letta's sleep-time compute,
Anthropic's Dreaming / Auto Dream) that the export's own layout belongs to.

## 1. What the export actually shows

The agent's home directory, as listed in the article:

```
SOUL.md  IDENTITY.md  USER.md  MEMORY.md  AGENTS.md  TOOLS.md
agents/   docs/   devices/home_link.md
memory/bank/     memory/dreams/     workspace/self_improvement/
opt/hatch/skills/     opt/hatch-image/bin/codex (+ bwrap)
```

Three things are worth separating out:

- **`memory/bank/` versus `memory/dreams/`** — the durable store and *the products of consolidation*
  are different directories. Dreams are artifacts, not edits to memory.
- **`workspace/self_improvement/`** — the agent has a first-class place to work on itself. That is
  RubyClaw's entire thesis, and this is the directory shape for it.
- **The article's actual complaint** — the runtime left through "an ordinary conversation and a
  connected export destination". The lesson is not "agents are dangerous"; it is that **the same
  agent that can read its own memory must not be able to send it anywhere**. A consolidation pass is
  the single most dangerous thing to give network access, because it reads everything and writes
  what it concluded.

What RubyClaw already has: `SOUL.md` with layering (`instance/SOUL.md` → `SOUL.md` → built-in),
durable markdown notes, a work store with approvals, a scheduler, skills, and — crucially — a
**non-negotiable rule that self-writes are never promoted on trust**. That rule is the same
discipline as the field's "the input store is never modified; you review the output".

Gaps against the layout: no `IDENTITY.md`, no `AGENTS.md`, no generated `TOOLS.md`, no
`memory/bank` versus `memory/dreams` split, no `self_improvement` workspace.

## 2. The dream, concretely

`claw dream` — a scheduled, offline pass that consolidates what the agent has accumulated.

- **Trigger**: at least 24 h since the last dream **and** at least 5 new sessions (both, so a quiet
  day does not dream about nothing). RubyClaw already has a scheduler; this is a job on it.
- **Input**: the notes store, the session transcripts, the work store. Read-only.
- **Output**: one new dated artifact, `memory/dreams/YYYY-MM-DD.md`, plus proposed memory writes.
  The input store is **never** mutated — the dream writes only into its own artifact.
- **Phases** (the shape the working implementations converged on, and the token-frugal one):
  1. **Orient** — read the memory index and the existing topic files; build a map before touching
     anything.
  2. **Gather signal** — grep the transcripts for corrections, explicit saves, repeated patterns and
     architecture decisions. Specifically *not* an exhaustive read: look for what is already
     suspected to matter.
  3. **Consolidate** — relative dates become absolute (`"yesterday we decided"` →
     `"on 2026-03-15 we decided"`); duplicates merge; contradictions resolve with the newest ground
     truth winning and the loser deleted at source; episodic traces become one general rule
     (*"the token is in STAGING_API_KEY"* ×4 → *"this service reads every credential from the
     environment, never from config"*).
  4. **Prune and index** — a hard line budget on the index, because it loads on every session.
- **Validation — the RubyClaw-specific part.** A dream's proposed memory writes are *not applied*.
  They go through the existing approval machinery, which means they arrive in Telegram with
  Approve/Deny buttons and `/approvals`. The field's implementations all have a human review step;
  RubyClaw already has the machinery, so the review step is not new code, it is the existing path.
  `auto_apply` should exist as an explicit, off-by-default switch, never as the default.
- **The sandbox rule.** The dream pass gets **one tool: read transcripts, write its own artifact.**
  No `http.send`, no FTP, no browser, no host terminal. Expressed in `policy.yml` as its own named
  action so `claw policy` shows the boundary, the same way `http.get` and `http.send` are split
  today. This is the article's lesson made structural: the pass that can read everything cannot
  send anything.

## 3. Ordered work

1. **`claw dream`** — the pass itself: trigger check, read-only gather, dated artifact under
   `memory/dreams/`, proposals routed to `Work.request_approval` with the dream path attached.
   Acceptance: a run against a fixture store produces one dated artifact, leaves every input file
   byte-identical, and lands an approval; a dream with the network tools stripped cannot
   exfiltrate even when instructed to.
2. **`TOOLS.md`, `IDENTITY.md`, `AGENTS.md`** — `claw tools` already knows the tool surface, so
   `TOOLS.md` should be *generated* from it rather than hand-written, and regenerated on change.
   `IDENTITY.md` is the stable "what I am" next to `SOUL.md`'s "how I am"; `AGENTS.md` is the
   project rules file. All three are cheap and make the harness legible to a new model.
3. **The bank/dreams split** — `memory/bank/` for consolidated, reviewed memory;
   `memory/dreams/` for the raw artifacts. A dream's proposals, once approved, write into the bank,
   with `dream_path` recorded so any bank entry can be traced to the dream that produced it. That
   traceability is what makes a bad consolidation recoverable — the field's open failure mode is
   "a bad consolidation persists and compounds", and provenance is the answer to it.
4. **`workspace/self_improvement/`** — where the harness writes proposals about *its own code*,
   as patches for review, never applied directly.
5. **Scheduled work, visible** — the dream is the first job that is expected to run unattended and
   report. `claw` should show last-run, next-run and last-dream, so silence is never ambiguous.

## 4. What I could not read

The article's figures — including the screenshot of a real dream entry with its `dream_path` and
synthesis metadata — did not come through. Shell egress from this machine to that host returns
nothing (a plain `curl -o` writes no file) and the browser daemon timed out on `Page.navigate`, so
the figures are read here as captions, not as images. The dream-entry schema above is therefore
described from the surrounding text and the field's implementations, not copied from the screenshot.
If that schema matters, re-sending it as an image is the fix — a URL I cannot reach is the one thing
that blocks it.
