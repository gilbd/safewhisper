#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${HOME}/.safewhisper"
RUN_DIR="${STATE_DIR}/run"
APP_DIR="${STATE_DIR}/bin"
VENV_DIR="${STATE_DIR}/venv"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.safewhisper.helper.plist"

command -v docker >/dev/null || { echo "Docker is required. Install/start Docker Desktop first." >&2; exit 1; }
PYTHON_BIN="${SAFEWHISPER_PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in "$(command -v python3.11 2>/dev/null || true)" "/opt/homebrew/bin/python3.11" "/usr/local/bin/python3.11" "$HOME/.hermes/hermes-agent/venv/bin/python3.11"; do
    if [[ -x "$candidate" ]]; then PYTHON_BIN="$candidate"; break; fi
  done
fi
[[ -n "$PYTHON_BIN" ]] || { echo "Python 3.11+ is required. Install it with: brew install python@3.11" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift/Xcode Command Line Tools are required." >&2; exit 1; }

mkdir -p "$RUN_DIR" "$APP_DIR" "${HOME}/Library/LaunchAgents"
rm -f "$RUN_DIR/engine.sock" "$RUN_DIR/helper.sock"

if [[ ! -x "$VENV_DIR/bin/python" ]] || ! "$VENV_DIR/bin/python" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
  rm -rf "$VENV_DIR"
  echo "[1/6] Creating SafeWhisper host helper environment"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
else
  echo "[1/6] Reusing SafeWhisper host helper environment"
fi
"$VENV_DIR/bin/pip" install --quiet --no-deps "$ROOT_DIR"
docker compose -f "$ROOT_DIR/docker-compose.yml" build

echo "[2/4] Starting engine with network disabled"
docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

python3 - "$ROOT_DIR/scripts/com.safewhisper.helper.plist.template" "$PLIST_PATH" "$ROOT_DIR" "$VENV_DIR" "$HOME" <<'PY'
import pathlib, sys
source, target, root, venv, home = map(pathlib.Path, sys.argv[1:])
text = source.read_text()
text = text.replace("__ROOT_DIR__", str(root)).replace("__VENV__", str(venv)).replace("__HOME__", str(home))
target.write_text(text)
PY
launchctl bootout "gui/$(id -u)/com.safewhisper.helper" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.safewhisper.helper"

echo "[3/4] Building SafeWhisper macOS client"
(
  cd "$ROOT_DIR/macos"
  swift build -c release
  cp .build/arm64-apple-macosx/release/SafeWhisperMac "$APP_DIR/SafeWhisperMac"
)
chmod +x "$APP_DIR/SafeWhisperMac"

echo "[4/4] Installation complete"
echo "Helper socket: $RUN_DIR/helper.sock"
echo "Client: $APP_DIR/SafeWhisperMac"
echo "Run the client manually, then grant Microphone and Accessibility permissions when macOS asks."
