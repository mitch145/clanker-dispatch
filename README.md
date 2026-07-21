# clanker-dispatch

Fire-and-forget Claude Code session dispatch for the clanker box.

Publish `implement 1234` to an ntfy topic from your phone → a Claude Code
session spawns in a tmux window on this machine → the session self-registers
with Remote Control → you manage it entirely from the Claude mobile app.

```
┌─────────┐  push msg   ┌──────────┐  spawns   ┌─────────────┐
│ ntfy app │ ──────────▶ │ listener │ ────────▶ │ tmux window │
│ (phone)  │ ◀────────── │ (systemd)│           │ claude /sl-*│
└─────────┘  "Spawned"  └──────────┘           └──────┬──────┘
      ▲                                               │ Remote Control
      │              push notifications               ▼ auto-register
┌─────┴────────────────────────────────────────────────────┐
│                 Claude mobile app (Code tab)              │
│        steer / approve / read output / finish             │
└──────────────────────────────────────────────────────────┘
```

## Components

| Path | Purpose |
|---|---|
| `bin/spawn` | Creates a tmux window running a named Claude session per the verb map. Idempotent per action+id. |
| `bin/dispatch-listener` | Subscribes to the ntfy topic over raw HTTP, validates messages (text or JSON), calls `spawn`, publishes confirmation. |
| `bin/sitrep` | One-screen box/session health check for low-bandwidth diagnosis over mosh. |
| `systemd/ntfy-dispatch.service` | User unit keeping the listener alive across crashes and reboots. |
| `Makefile` | Ops wrapper — `make doctor` checks every layer without changing anything. |
| `.env.example` | Template for `~/.config/clanker/env` (token, topic, repo path). |
| `install.sh` | Symlinks bin/, installs the unit, enables lingering. |

`bin/` is the single source of truth: `install.sh` **symlinks** it into
`~/.local/bin`, so a regular file left there gets silently replaced on the
next install. Edit here, never there.

## One-time setup

### 1. ntfy

1. Account at https://ntfy.sh → Account → Access tokens → create, copy `tk_...`
2. Generate an unguessable topic: `echo "clanker-dispatch-$(openssl rand -hex 8)"`
   The topic name is the access control on free tier. Treat it like a password.
   Do not commit it. Do not reuse a name you've pasted into chats/docs.
3. Phone: install ntfy (iOS/Android), log in, subscribe to the topic.
   Notification sound on — this topic carries both your commands and the
   box's confirmations/alerts.

### 2. Claude Code (on this box)

Inside any `claude` session:

- `/config` → **Enable Remote Control for all sessions** → `true`
  (every spawned session self-registers in the Claude app)
- `/config` → **Push when actions required** → on
- `/config` → **Push when Claude decides** → on (optional but useful)

Requires claude.ai login (`/login`), not an API key, and no
`ANTHROPIC_BASE_URL` override in the environment the sessions run in —
Remote Control is disabled behind gateways/proxies. GLM/Z.ai sessions
therefore can't use this pipeline; drive those over mosh+tmux directly.

Also run `claude` once in the repo directory to accept workspace trust.

### 3. Install

```bash
git clone <this repo> ~/src/clanker-dispatch
cd ~/src/clanker-dispatch
cp .env.example ~/.config/clanker/env   # then edit: token, topic, repo dir
./install.sh
```

### 4. Test

```bash
journalctl --user -u ntfy-dispatch -f
```

From the phone, publish: `implement 9999` (9999 is deliberately not a real
ticket). Expect, in order:

1. Journal shows `dispatch: implement 9999` and the spawn
2. `tmux list-windows -t work` shows a `ship-9999` window
3. "Spawned" push arrives on the phone
4. Session appears in Claude app → Code tab within ~15s, named `ship-9999`
5. It stops within seconds on a tool permission prompt — approve from the
   phone. That prompt *is* the pipeline working; silence it later by
   allowlisting the tool in the target repo.
6. Publishing `implement 9999` again pushes "Already up", not "started"

Kill the test window: `tmux kill-window -t work:ship-9999`

`make dispatch VERB=new` is the cheapest smoke test — a bare session with no
slash command, nothing to damage.

## Message protocol

```
<verb> [id] [extra context...]
```

Each verb answers to both the intent word and its command's own name, so you
never have to recall which vocabulary this wants:

| verb | slash command | id space | window |
|---|---|---|---|
| `implement` / `ship` | `/sl-ship` | ticket | `ship-1234` |
| `plan` | `/sl-plan` | ticket | `plan-1234` |
| `style` | `/sl-style` | ticket | `style-1234` |
| `cleanup` | `/sl-cleanup` | ticket | `cleanup-1234` |
| `review` | `/sl-review` | **PR number** | `review-3771` |
| `continue` / `revise` | `/sl-revise` | **PR number** | `revise-3771` |
| `status` | `/sl-status` | none | `status` |
| `new` / `session` | *(none — bare session)* | none | `new`, `new-2`, … |

- `id`: 1–6 digits. `SLATE-`, `slate-` and `#` prefixes are stripped.
  `review` expands a bare number into a full GitHub PR URL, because
  `/sl-review` takes a URL and not a ticket — the two id spaces are
  different and don't share validation.
- Trailing text is appended after ` — `. For `new` it *is* the prompt.
- Window name is `<action>-<number>`, keyed on the action as well as the id:
  reviewing a PR and then revising it is an ordinary sequence and must not
  collide. It doubles as the session name in the Claude app.

### Sending from a phone

iOS: the ntfy app is **receive-only** — it cannot publish. Use a Shortcut
(Get Contents of URL → POST → Request Body **JSON**) or the web app at
ntfy.sh/app. Shortcuts defaults its body to JSON, so the listener accepts
JSON as well as plain text — all three of these are the same dispatch:

```
implement 9999                  # plain text
{"message":"implement 9999"}    # Shortcuts, key `message` — handles any verb
{"implement":"9999"}            # Shortcuts, verb as the key
```

Prefer the `message` form: one shortcut shape covers every verb, and it
survives appending extra context.

### What gets ignored

Non-dispatch traffic is skipped but *logged* (`ignored (not a dispatch): …`)
— a typo'd verb is otherwise indistinguishable from a dead listener.

The listener tags its own publishes `clanker-ack` and skips tagged messages.
Commands and confirmations share one topic, so without that a confirmation
whose body happens to parse as a dispatch re-triggers a spawn, forever. Do
not rely on confirmation *wording* to fail validation — that guarantee lasted
exactly as long as it took someone to reword a push.

**Keep dispatch messages content-free** (verb + number only). They transit
ntfy.sh. Steering with real context happens in the Claude app, which rides
Anthropic's channel.

## Security model

- Topic name = credential (free tier). High-entropy, never published.
- Token-authenticated publishes/subscribes on top of that.
- Listener validates against a verb allowlist and a numeric id — no raw
  strings reach the shell, and `spawn` runs every interpolation through
  `printf %q`, so a free-text tail containing `; touch /tmp/PWNED` arrives
  as literal prompt text rather than a command.
- `spawn` is idempotent per action+id (tmux window name check), so replay
  after listener restart (`since=10m`) can't double-spawn. It exits 3 on a
  skip, which the listener reports as "Already up" rather than "started" —
  a redelivery must not push a confirmation that nothing actually began.
  `new` opts out and suffixes (`new-2`), being a blank session rather than
  a claim on a work item.
- Sessions run with `--permission-mode auto` (`CLANKER_PERMISSION_MODE`).
  The CLI default is `manual`, which leaves an unattended session waiting on
  a keystroke nobody is at the box to give.
- Permission model: do NOT run these sessions with
  `--dangerously-skip-permissions` or `--permission-mode bypassPermissions`. Instead allowlist the tools your
  `sl-*` flows use in the repo's `.claude/settings.json`
  (`permissions.allow`) and approve the rest from the phone via
  Remote Control pushes.

## Operations

```bash
make            # the menu
make doctor     # check every layer, change nothing — start here when it breaks
make logs       # live journal (Ctrl-C exits the view, not the listener)
make status     # is the listener up
make restart    # after editing bin/ or the env file
make topic      # the topic name to subscribe to on a phone
make dispatch VERB=implement TICKET=1234   # publish from the box itself
sitrep          # box + session overview
tmux attach -t work                        # post-mortem a session locally
```

Known failure modes:
- **No "Spawned" push after dispatch** → listener down or token/topic wrong.
  `make restart`, then `make logs`. If the journal shows
  `ignored (not a dispatch)`, the message reached the box and the *verb* was
  wrong — check it against the table above.
- **Session spawned but not in Claude app** → Remote Control auto-connect
  not enabled, signed out (`/login`), or ANTHROPIC_BASE_URL set.
- **Every session in the app has a derived name** (`slate-a8`, `slate-e7`) →
  `spawn` lost its `-n` / `--remote-control=` flags. Concurrent sessions
  become indistinguishable, which reads exactly like "it never showed up".
  Verify with `jq '{name,nameSource}' ~/.claude/sessions/<pid>.json`:
  `name` should be the window name and `nameSource` must not be `derived`.
- **Session stalls seconds after starting** → it hit a tool permission
  prompt. Allowlist that tool in the *target repo's* `.claude/settings.json`.
  Match the MCP server's registered name exactly: a server registered as
  `linear-server` produces `mcp__linear-server__*`, which `mcp__linear__*`
  does **not** match.
- **Session vanished from app** → box offline >10 min kills Remote Control
  registration; the tmux window and session survive locally. Re-run
  `/remote-control` in the window or restart the task.
- **tmux server disappears with no OOM line in dmesg and free memory
  system-wide** → a cgroup-local kill. Do not put `MemoryMax` on the unit:
  a tmux server created by the listener inherits the service cgroup, so a cap
  meant to bound a bash+curl loop ends up bounding every Claude session it
  holds. `spawn` also starts the server via `systemd-run --user --scope` to
  escape that cgroup.

## Retirement criteria

Delete `dispatch-listener` when the Claude app ships client-side session
spawning against `claude remote-control` server mode
(anthropics/claude-code#34626 was closed unplanned; capacity exists,
client UI doesn't — yet). `spawn` stays useful regardless.
