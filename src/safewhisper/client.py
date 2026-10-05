"""Minimal host-side client for the isolated Unix-socket engine."""
from __future__ import annotations

import base64
import json
import socket
from pathlib import Path

from .core import normalize_transcript


def request(socket_path: str, payload: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(300)
        client.connect(socket_path)
        client.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode("utf-8"))


def transcribe_file(audio_path: str, socket_path: str) -> str:
    path = Path(audio_path)
    response = request(socket_path, {
        "type": "transcribe",
        "suffix": path.suffix or ".wav",
        "audio_base64": base64.b64encode(path.read_bytes()).decode("ascii"),
    })
    if not response.get("ok"):
        raise RuntimeError(response.get("error", "transcription failed"))
    return normalize_transcript(response.get("text", ""))
