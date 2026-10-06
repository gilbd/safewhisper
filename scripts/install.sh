#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${HOME}/.safewhisper"
RUN_DIR="${STATE_DIR}/run"
APP_DIR="${STATE_DIR}/bin"

command -v docker >/dev/null || { echo "Docker is required. Install/start Docker Desktop first." >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift/Xcode Command Line Tools are required." >&2; exit 1; }

mkdir -p "$RUN_DIR" "$APP_DIR"
rm -f "$RUN_DIR/engine.sock"

echo "[1/4] Building isolated STT engine image"
docker compose -f "$ROOT_DIR/docker-compose.yml" build

echo "[2/4] Starting engine with network disabled"
docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

echo "[3/4] Building SafeWhisper macOS client"
(
  cd "$ROOT_DIR/macos"
  swift build -c release
  cp .build/arm64-apple-macosx/release/SafeWhisperMac "$APP_DIR/SafeWhisperMac"
)
chmod +x "$APP_DIR/SafeWhisperMac"

echo "[4/4] Installation complete"
echo "Engine socket: $RUN_DIR/engine.sock"
echo "Client: $APP_DIR/SafeWhisperMac"
echo "Run the client manually, then grant Microphone and Accessibility permissions when macOS asks."
