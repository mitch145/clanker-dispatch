---
name: clank
description: Dispatch a clanker background agent for a ticket/PR — csli, cslc, cslr, csln, "spin out an implementer", "dispatch an agent at 5506". Runs bin/spawn on this box; the session self-registers in the Claude app and the clanker panel. ONLY when the user explicitly asks for an agent to be spun out — never proactively, never as a side effect of other work.
---

# clank — dispatch a background agent

Run `~/.local/bin/spawn <verb> [id] [extra context...]` via Bash. That is the
whole mechanism — spawn handles config, PR resolution, naming, idempotency,
and Remote Control registration itself. Do not reimplement any of it, and do
not cd anywhere first; spawn reads `~/.config/clanker/env`.

## Verbs

| user says | run | notes |
|---|---|---|
| csli / implement / ship | `spawn implement <ticket>` | |
| cslc / continue / revise | `spawn continue <ticket>` | resumes the ticket's previous ship/revise session when one exists — warm context |
| cslr / review | `spawn review <ticket-or-pr>` | resolves ticket → PR URL itself |
| csln / new session | `spawn new [prompt...]` | trailing text is the opening prompt |
| plan / style / cleanup / status | `spawn <verb> <ticket>` | same shape |

- Ticket ids: 1–6 digits; `SLATE-`/`#` prefixes are fine, spawn strips them.
- Extra context after the id is passed through: `spawn implement 5506 stack on the parent PR`.
- Several tickets → one spawn call each, sequentially.

## Reading the result

- exit 0 — spawned; echo spawn's own output line to the user (it records the
  label and any ticket→PR resolution).
- exit 3 — a live session with that name already exists. Not an error: say
  "already running", do not retry, do not stop it.
- other — report the exit code and spawn's stderr verbatim.

Afterwards tell the user where it lands: the session appears in the Claude
app (Code tab) and on the clanker panel, named `<action>-<ticket>`.

## Boundaries

- Dispatch ONLY what the user explicitly asked for, verb and ticket both.
  "Look into 5506" is not a dispatch request; "spin out an implementer for
  5506" / "csli 5506" is.
- Never stop, steer, or answer another agent's prompts from here unless
  asked; that lives in the Claude app.
- If spawn is missing or the env file is absent, this box isn't set up for
  dispatch — say so and point at `make doctor` in
  `~/Projects/personal/clanker-dispatch`; do not improvise a `claude --bg`
  invocation yourself.
