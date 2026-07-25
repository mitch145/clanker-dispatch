#!/usr/bin/env bash
# Installs clanker-dispatch: symlinks bin/ into ~/.local/bin, installs the
# systemd user unit, enables lingering so it runs without a login session.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# Deps
for dep in curl jq tmux claude; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done

# Config
mkdir -p "$HOME/.config/clanker"
if [[ ! -f "$HOME/.config/clanker/env" ]]; then
  cp .env.example "$HOME/.config/clanker/env"
  chmod 600 "$HOME/.config/clanker/env"
  echo ">> Created ~/.config/clanker/env from template — EDIT IT before starting."
  NEEDS_EDIT=1
fi

# Binaries
mkdir -p "$HOME/.local/bin"
for f in bin/*; do
  chmod +x "$f"
  ln -sf "$(readlink -f "$f")" "$HOME/.local/bin/$(basename "$f")"
done
echo ">> Symlinked $(ls bin | tr '\n' ' ')into ~/.local/bin"

# Skills: any Claude session on this box can dispatch agents when — and only
# when — explicitly asked. Symlinked like bin/, so the repo stays the source
# of truth. rm first: `ln -sf` onto an existing dir symlink nests instead of
# replacing.
mkdir -p "$HOME/.claude/skills"
for d in skills/*/; do
  [[ -d "$d" ]] || continue
  tgt="$HOME/.claude/skills/$(basename "$d")"
  [[ -L "$tgt" ]] && rm -f "$tgt"
  ln -s "$(readlink -f "$d")" "$tgt"
done
echo ">> Symlinked $(ls skills | tr '\n' ' ')into ~/.claude/skills"

# The UI refuses to start without a token. Mint one on first install rather
# than leaving a REPLACE_ME that only announces itself as a failed unit later.
if ! grep -q '^CLANKER_UI_TOKEN=' "$HOME/.config/clanker/env" \
   || grep -q '^CLANKER_UI_TOKEN=REPLACE_ME' "$HOME/.config/clanker/env"; then
  tok="$(openssl rand -hex 16)"
  if grep -q '^CLANKER_UI_TOKEN=' "$HOME/.config/clanker/env"; then
    sed -i "s|^CLANKER_UI_TOKEN=.*|CLANKER_UI_TOKEN=$tok|" "$HOME/.config/clanker/env"
  else
    printf '\n# mobile control panel (bin/clanker-ui)\nCLANKER_UI_TOKEN=%s\nCLANKER_UI_PORT=8787\n' \
      "$tok" >> "$HOME/.config/clanker/env"
  fi
  echo ">> Generated CLANKER_UI_TOKEN."
fi

# systemd user units. Globbed per-pattern: a bare `cp systemd/*.service
# systemd/*.timer` fails the whole install the moment one pattern matches
# nothing, which with `set -e` aborts before anything gets enabled.
mkdir -p "$HOME/.config/systemd/user"
shopt -s nullglob
units=(systemd/*.service systemd/*.timer)
shopt -u nullglob
(( ${#units[@]} )) && cp "${units[@]}" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
loginctl enable-linger "$USER"

if [[ "${NEEDS_EDIT:-0}" == "1" ]]; then
  echo ">> Now: edit ~/.config/clanker/env, then:"
  echo "   systemctl --user enable --now ntfy-dispatch"
else
  systemctl --user enable --now ntfy-dispatch clanker-ui
  systemctl --user restart ntfy-dispatch clanker-ui

  echo ">> Listener and UI enabled and started."
  echo ">> Phone URL: make ui-url"
fi
echo ">> Verify: journalctl --user -u ntfy-dispatch -f"
