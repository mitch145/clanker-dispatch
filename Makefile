# clanker-dispatch ops — the four systemd incantations you'd otherwise memorise,
# plus a doctor that checks every layer of the pipeline. `make` shows the menu.
SHELL := /bin/bash
UNIT  := ntfy-dispatch
ENV   := $(HOME)/.config/clanker/env

.DEFAULT_GOAL := help
.PHONY: help install start stop restart status logs sitrep doctor dispatch topic \
        sessions sweep kill worktrees

# A window's pane_current_command is the wrapper shell, not claude, so liveness
# has to come from the process table. Anchor on ( |$) — plain `=new` is a prefix
# of `=new-2` and would report a dead window as live.
LIVE = pgrep -f -- "--remote-control=$$w( |$$)" >/dev/null 2>&1

help: ## Show this menu
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /\t/' | awk -F'\t' '{printf "  %-9s %s\n", $$1, $$2}'

install: ## Symlink bin/, install the systemd unit, enable lingering
	@./install.sh

start: ## Start now + at every boot
	systemctl --user enable --now $(UNIT)

stop: ## Stop now + don't start at boot
	systemctl --user disable --now $(UNIT)

restart: ## Restart — do this after editing bin/ or the env file
	systemctl --user restart $(UNIT)

status: ## Is the listener up?
	@systemctl --user status $(UNIT) --no-pager || true

logs: ## Follow the listener log live (Ctrl-C exits the view, not the listener)
	journalctl --user -u $(UNIT) -f

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

sessions: ## List spawned windows and whether each still has a live claude
	@set -a; . $(ENV); set +a; s=$${CLANKER_TMUX_SESSION:-work}; \
	tmux has-session -t $$s 2>/dev/null || { echo "  (no tmux session)"; exit 0; }; \
	for w in $$(tmux list-windows -t $$s -F '#W'); do \
	  if $(LIVE); then st="LIVE"; else st="finished"; fi; \
	  printf "  %-18s %s\n" "$$w" "$$st"; \
	done

# Windows outlive claude on purpose (`exec $$SHELL`) so the scrollback survives
# for a post-mortem — which means they accumulate until something reaps them.
sweep: ## Kill finished windows, leave live sessions running
	@set -a; . $(ENV); set +a; s=$${CLANKER_TMUX_SESSION:-work}; \
	tmux has-session -t $$s 2>/dev/null || { echo "  (no tmux session)"; exit 0; }; \
	n=0; \
	for w in $$(tmux list-windows -t $$s -F '#W'); do \
	  case "$$w" in \
	    ship-*|plan-*|style-*|cleanup-*|review-*|revise-*|status|new|new-*) ;; \
	    *) continue ;; \
	  esac; \
	  if $(LIVE); then echo "  keep  $$w (live)"; \
	  else tmux kill-window -t "$$s:$$w" && echo "  swept $$w"; n=$$((n+1)); fi; \
	done; \
	echo "  swept $$n window(s)"

kill: ## make kill W=ship-1234 — kill one window, live or not
	@[[ -n "$(W)" ]] || { echo "usage: make kill W=ship-1234" >&2; exit 2; }
	@set -a; . $(ENV); set +a; s=$${CLANKER_TMUX_SESSION:-work}; \
	tmux kill-window -t "$$s:$(W)" && echo "  killed $(W)"

worktrees: ## Show git worktrees the sessions have created in the target repo
	@set -a; . $(ENV); set +a; \
	git -C "$$CLANKER_REPO" worktree list; \
	echo "  remove one:  git -C $$CLANKER_REPO worktree remove <path>"; \
	echo "  or dispatch: cleanup <ticket>   (runs /sl-cleanup, closes the loop properly)"

doctor: ## Check every layer without changing anything
	@fail=0; \
	for d in curl jq tmux claude; do \
	  command -v $$d >/dev/null && echo "  ok    dep $$d" || { echo "  FAIL  dep $$d missing"; fail=1; }; \
	done; \
	if [[ -f $(ENV) ]]; then \
	  [[ "$$(stat -c %a $(ENV))" == 600 ]] && echo "  ok    $(ENV) (600)" \
	    || echo "  warn  $(ENV) is mode $$(stat -c %a $(ENV)), want 600"; \
	  set -a; . $(ENV); set +a; \
	  [[ "$$NTFY_TOKEN" == tk_* ]] && echo "  ok    NTFY_TOKEN set" || { echo "  FAIL  NTFY_TOKEN unset/placeholder"; fail=1; }; \
	  [[ "$$NTFY_TOPIC_URL" != *REPLACE_ME* ]] && echo "  ok    topic $${NTFY_TOPIC_URL##*/}" || { echo "  FAIL  NTFY_TOPIC_URL still a placeholder"; fail=1; }; \
	  [[ -d "$$CLANKER_REPO/.claude/commands" ]] && echo "  ok    repo $$CLANKER_REPO" || { echo "  FAIL  CLANKER_REPO has no .claude/commands: $$CLANKER_REPO"; fail=1; }; \
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
	exit $$fail
