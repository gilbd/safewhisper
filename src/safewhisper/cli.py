"""SafeWhisper command-line client."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .client import request, transcribe_file


def main() -> None:
    parser = argparse.ArgumentParser(prog="safewhisper")
    parser.add_argument(
        "--socket",
        default=os.environ.get("SAFEWHISPER_SOCKET", str(Path.home() / ".safewhisper/run/helper.sock")),
        help="Unix socket exposed by the SafeWhisper engine",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    health = subparsers.add_parser("health")
    health.set_defaults(handler=lambda args: print(json.dumps(request(args.socket, {"type": "health"}), ensure_ascii=False)))

    transcribe = subparsers.add_parser("transcribe")
    transcribe.add_argument("audio_file")
    transcribe.set_defaults(handler=lambda args: print(transcribe_file(args.audio_file, args.socket)))

    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
