"""Unix-socket STT engine. The container can run with network disabled."""
from __future__ import annotations

import base64
import json
import os
import socketserver
import tempfile
from pathlib import Path

from faster_whisper import WhisperModel

SOCKET_PATH = Path(os.environ.get("WHISPERFLOW_SOCKET", "/run/whisperflow/engine.sock"))
MODEL_NAME = os.environ.get("WHISPERFLOW_MODEL", "ivrit-ai/whisper-large-v3-turbo-ct2")
MODEL_DEVICE = os.environ.get("WHISPERFLOW_DEVICE", "cpu")
MODEL_COMPUTE = os.environ.get("WHISPERFLOW_COMPUTE", "int8")

MODEL = WhisperModel(MODEL_NAME, device=MODEL_DEVICE, compute_type=MODEL_COMPUTE)


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        raw = self.rfile.readline(64 * 1024 * 1024)
        if not raw:
            return
        try:
            request = json.loads(raw)
            if request.get("type") == "health":
                response = {"ok": True, "model": MODEL_NAME, "device": MODEL_DEVICE, "compute_type": MODEL_COMPUTE}
            elif request.get("type") == "transcribe":
                response = self._transcribe(request)
            else:
                response = {"ok": False, "error": "unknown request type"}
        except Exception as exc:  # protocol boundary must always return JSON
            response = {"ok": False, "error": str(exc)}
        self.wfile.write((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))

    def _transcribe(self, request: dict) -> dict:
        encoded = request.get("audio_base64")
        if not encoded:
            return {"ok": False, "error": "audio_base64 is required"}
        audio = base64.b64decode(encoded, validate=True)
        if not audio or len(audio) > 25 * 1024 * 1024:
            return {"ok": False, "error": "audio is empty or too large"}
        suffix = request.get("suffix", ".wav")
        with tempfile.NamedTemporaryFile(prefix="whisperflow-", suffix=suffix, delete=True) as temp:
            temp.write(audio)
            temp.flush()
            segments, info = MODEL.transcribe(temp.name, language=None, vad_filter=True)
            text = " ".join(segment.text.strip() for segment in segments).strip()
        return {"ok": True, "text": text, "language": getattr(info, "language", None)}


def main() -> None:
    SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True)
    SOCKET_PATH.unlink(missing_ok=True)
    with socketserver.UnixStreamServer(str(SOCKET_PATH), Handler) as server:
        os.chmod(SOCKET_PATH, 0o660)
        server.serve_forever()


if __name__ == "__main__":
    main()
