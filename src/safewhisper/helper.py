"""Host-only Unix-socket proxy for the isolated SafeWhisper engine."""
from __future__ import annotations

import argparse
import json
import os
import selectors
import socket
import socketserver
import subprocess
import threading
from pathlib import Path

DEFAULT_SOCKET = Path.home() / ".safewhisper/run/helper.sock"
DEFAULT_CONTAINER = "safewhisper-engine"
DEFAULT_DOCKER = "/usr/local/bin/docker"
MAX_REQUEST = 64 * 1024 * 1024

BRIDGE_CODE = r'''
import socket, sys
while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/run/safewhisper/engine.sock")
    s.sendall(line)
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("engine socket closed")
        data += chunk
    s.close()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
'''


class Bridge:
    def __init__(self, container: str) -> None:
        self.container = container
        self._lock = threading.Lock()
        self._process: subprocess.Popen[bytes] | None = None
        self._start()

    def _start(self) -> None:
        self._process = subprocess.Popen(
            [
                os.environ.get("SAFEWHISPER_DOCKER", DEFAULT_DOCKER),
                "exec",
                "-i",
                self.container,
                "python",
                "-u",
                "-c",
                BRIDGE_CODE,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

    def _alive(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def request(self, payload: bytes) -> bytes:
        with self._lock:
            if not self._alive():
                self._start()
            assert self._process is not None
            assert self._process.stdin is not None
            assert self._process.stdout is not None
            try:
                self._process.stdin.write(payload)
                self._process.stdin.flush()
                selector = selectors.DefaultSelector()
                selector.register(self._process.stdout, selectors.EVENT_READ)
                data = b""
                while not data.endswith(b"\n"):
                    ready = selector.select(timeout=300)
                    if not ready:
                        raise TimeoutError("engine request timed out")
                    chunk = self._process.stdout.readline()
                    if not chunk:
                        raise RuntimeError("engine bridge closed")
                    data += chunk
                return data
            except Exception:
                self._process.kill()
                self._process.wait()
                raise


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        raw = self.rfile.readline(MAX_REQUEST + 1)
        if not raw or len(raw) > MAX_REQUEST or not raw.endswith(b"\n"):
            self._write({"ok": False, "error": "invalid request"})
            return
        try:
            request = json.loads(raw)
            if not isinstance(request, dict) or request.get("type") not in {"health", "transcribe"}:
                raise ValueError("unsupported request type")
            response = self.server.bridge.request(raw)  # type: ignore[attr-defined]
            self.wfile.write(response)
        except Exception as exc:
            self._write({"ok": False, "error": str(exc)})

    def _write(self, payload: dict) -> None:
        self.wfile.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=os.environ.get("SAFEWHISPER_HELPER_SOCKET", str(DEFAULT_SOCKET)))
    parser.add_argument("--container", default=os.environ.get("SAFEWHISPER_CONTAINER", DEFAULT_CONTAINER))
    args = parser.parse_args()

    socket_path = Path(args.socket).expanduser()
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    socket_path.unlink(missing_ok=True)
    bridge = Bridge(args.container)
    with Server(str(socket_path), Handler) as server:
        server.bridge = bridge  # type: ignore[attr-defined]
        os.chmod(socket_path, 0o600)
        server.serve_forever()


if __name__ == "__main__":
    main()
