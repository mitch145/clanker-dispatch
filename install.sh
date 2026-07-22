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

# systemd user unit
mkdir -p "$HOME/.config/systemd/user"
cp systemd/*.service systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
loginctl enable-linger "$USER"

if [[ "${NEEDS_EDIT:-0}" == "1" ]]; then
  echo ">> Now: edit ~/.config/clanker/env, then:"
  echo "   systemctl --user enable --now ntfy-dispatch"
else
  systemctl --user enable --now ntfy-dispatch
  systemctl --user restart ntfy-dispatch

  echo ">> Listener enabled and started."
fi
echo ">> Verify: journalctl --user -u ntfy-dispatch -f"
