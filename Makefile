# clanker-dispatch ops — the four systemd incantations you'd otherwise memorise,
# plus a doctor that checks every layer of the pipeline. `make` shows the menu.
SHELL := /bin/bash
UNIT  := ntfy-dispatch
UI    := clanker-ui
UNITS := $(UNIT) $(UI)
ENV   := $(HOME)/.config/clanker/env

.DEFAULT_GOAL := help
.PHONY: help install start stop restart status logs sitrep doctor dispatch topic \
        sessions kill worktrees ui-url ui-logs ui-fg

help: ## Show this menu
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /\t/' | awk -F'\t' '{printf "  %-9s %s\n", $$1, $$2}'

install: ## Symlink bin/, install the systemd units, enable lingering
	@./install.sh

# start/stop/status act on the whole system — listener AND control panel. They
# are two units because they fail independently (ntfy down != UI down), but
# there's no case where you want one of them running and not the other.
start: ## Start listener + UI now, and at every boot
	systemctl --user enable --now $(UNITS)

stop: ## Stop both now + don't start at boot
	systemctl --user disable --now $(UNITS)

restart: ## Restart both — do this after editing bin/ or the env file
	systemctl --user restart $(UNITS)

status: ## Are they up?
	@systemctl --user status $(UNITS) --no-pager || true

logs: ## Follow both logs live (Ctrl-C exits the view, not the services)
	journalctl --user -u $(UNIT) -u $(UI) -f

ui-logs: ## Follow just the control panel log
	journalctl --user -u $(UI) -f

# Pick the address the phone can actually reach. Preference order matters more
# than it looks: this box has seven global-scope v4 addresses, including WSL's
# loopback stub 10.255.255.254 (global scope, reachable from nothing) and a pile
# of docker bridges. A tailnet address (100.64/10) is the only one that works
# off the LAN, so it wins whenever one exists.
ui-url: ## Print the URL to open on your phone (contains the token — don't paste it around)
	@set -a; . $(ENV); set +a; \
	  host="$$(ip -4 -o addr show scope global 2>/dev/null \
	    | awk '$$2 !~ /^(lo|docker|br-|veth)/ {split($$4,a,"/"); print a[1]}' \
	    | grep -vx '10.255.255.254' \
	    | sort -t. -k1,1nr | awk '$$0 ~ /^100\./ {print; exit}')"; \
	  [[ -n "$$host" ]] || host="$$(ip -4 -o addr show scope global 2>/dev/null \
	    | awk '$$2 !~ /^(lo|docker|br-|veth)/ {split($$4,a,"/"); print a[1]}' \
	    | grep -vx '10.255.255.254' | head -1)"; \
	  echo "http://$$host:$${CLANKER_UI_PORT:-8787}/?t=$$CLANKER_UI_TOKEN"; \
	  echo; echo "Open once, then Add to Home Screen — the token is stored in a cookie."

ui-fg: ## Run the UI in this terminal (stop the service first) — for editing the page
	@set -a; . $(ENV); set +a; ./bin/clanker-ui

sitrep: ## One-screen box + session overview
	@./bin/sitrep

topic: ## Print the topic name to subscribe to on your phone
	@set -a; . $(ENV); set +a; echo "server:  https://ntfy.sh"; echo "topic:   $${NTFY_TOPIC_URL##*/}"

# Publish a dispatch from the box itself — same path the phone uses, useful for
# testing the pipeline without reaching for your pocket.
dispatch: ## make dispatch VERB=implement TICKET=1234  (TICKET optional: new, status)
	@[[ -n "$(VERB)" ]] || { echo "usage: make dispatch VERB=implement TICKET=1234" >&2; exit 2; }
	@set -a; . $(ENV); set +a; \
	  body="$$(echo $(VERB) $(TICKET))"; \
	  curl -sS --max-time 10 -H "Authorization: Bearer $$NTFY_TOKEN" \
	    -d "$$body" "$$NTFY_TOPIC_URL" >/dev/null \
	  && echo "published: $$body"

sessions: ## What's running right now, from claude agents
	@./bin/sessions list

kill: ## make kill N=ship-1234 — stop one background agent
	@[[ -n "$(N)" ]] || { echo "usage: make kill N=ship-1234" >&2; exit 2; }
	@./bin/sessions stop "$(N)"

worktrees: ## Show git worktrees the sessions have created in the target repo
	@set -a; . $(ENV); set +a; \
	git -C "$$CLANKER_REPO" worktree list; \
	echo "  remove one:  git -C $$CLANKER_REPO worktree remove <path>"; \
	echo "  or dispatch: cleanup <ticket>   (runs /sl-cleanup, closes the loop properly)"

doctor: ## Check every layer without changing anything
	@fail=0; \
	for d in curl jq claude python3; do \
	  command -v $$d >/dev/null && echo "  ok    dep $$d" || { echo "  FAIL  dep $$d missing"; fail=1; }; \
	done; \
	if [[ -f $(ENV) ]]; then \
	  [[ "$$(stat -c %a $(ENV))" == 600 ]] && echo "  ok    $(ENV) (600)" \
	    || echo "  warn  $(ENV) is mode $$(stat -c %a $(ENV)), want 600"; \
	  set -a; . $(ENV); set +a; \
	  [[ "$$NTFY_TOKEN" == tk_* ]] && echo "  ok    NTFY_TOKEN set" || { echo "  FAIL  NTFY_TOKEN unset/placeholder"; fail=1; }; \
	  [[ "$$NTFY_TOPIC_URL" != *REPLACE_ME* ]] && echo "  ok    topic $${NTFY_TOPIC_URL##*/}" || { echo "  FAIL  NTFY_TOPIC_URL still a placeholder"; fail=1; }; \
	  [[ -d "$$CLANKER_REPO/.claude/commands" ]] && echo "  ok    repo $$CLANKER_REPO" || { echo "  FAIL  CLANKER_REPO has no .claude/commands: $$CLANKER_REPO"; fail=1; }; \
	  [[ -n "$$CLANKER_UI_TOKEN" && "$$CLANKER_UI_TOKEN" != REPLACE_ME ]] \
	    && echo "  ok    CLANKER_UI_TOKEN set" \
	    || { echo "  FAIL  CLANKER_UI_TOKEN unset — clanker-ui refuses to start"; fail=1; }; \
	  curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$${CLANKER_UI_PORT:-8787}/api/state?t=$$CLANKER_UI_TOKEN" \
	    && echo "  ok    UI answering on :$${CLANKER_UI_PORT:-8787}" \
	    || echo "  warn  UI not answering on :$${CLANKER_UI_PORT:-8787} — make ui-logs"; \
	  for c in sl-review sl-ship sl-revise sl-plan sl-style sl-cleanup sl-status; do \
	    [[ -f "$$CLANKER_REPO/.claude/commands/$$c.md" ]] && echo "  ok    /$$c exists" || { echo "  FAIL  /$$c missing in repo"; fail=1; }; \
	  done; \
	else echo "  FAIL  $(ENV) missing — run make install"; fail=1; fi; \
	[[ -z "$$ANTHROPIC_BASE_URL" ]] && echo "  ok    no ANTHROPIC_BASE_URL (Remote Control works)" \
	  || { echo "  FAIL  ANTHROPIC_BASE_URL set — Remote Control is disabled behind gateways"; fail=1; }; \
	grep -q '"remoteControlAtStartup": *true' $(HOME)/.claude/settings.json 2>/dev/null \
	  && echo "  ok    remoteControlAtStartup: true" \
	  || echo "  warn  remoteControlAtStartup not true — sessions won't self-register"; \
	echo "  ---   listener: $$(systemctl --user is-enabled $(UNIT) 2>&1)/$$(systemctl --user is-active $(UNIT) 2>&1)"; \
	echo "  ---   ui:       $$(systemctl --user is-enabled $(UI) 2>&1)/$$(systemctl --user is-active $(UI) 2>&1)"; \
	exit $$fail
