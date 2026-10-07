# SafeWhisper

Local-first Hebrew + English speech-to-text for macOS.

SafeWhisper is designed for closed corporate networks:

- Global hotkey starts/stops recording.
- Audio is transcribed by a local `faster-whisper` engine.
- The engine runs in Docker with `network_mode: none`.
- The macOS app talks to a host-only Unix socket helper; the helper bridges requests through `docker exec` to the engine Unix socket.
- Transcript is copied to the clipboard and pasted into the active app.
- No audio or transcript is sent to a cloud transcription provider.

## Architecture

```text
[macOS app]
          |
          | host-only Unix socket: ~/.safewhisper/run/helper.sock
          v
[SafeWhisper host helper]
          |
          | fixed docker exec bridge
          v
[Docker: safewhisper-engine]
  network_mode: none
  ivrit-ai/whisper-large-v3-turbo-ct2
          |
          v
[clipboard + paste]
```

The model is downloaded only during `docker build`. Runtime has no network namespace. The container has a read-only root filesystem, a small tmpfs for transient audio, no Linux capabilities, and no-new-privileges enabled.

## Build and run

For local Python tooling:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
python -m pip install -e .
make test
```

Build and run the isolated engine:

```bash
docker compose build
docker compose up -d
```

The first build downloads the model and is large. Do it on a connected machine, then export/import the image or publish it to the company's approved registry before entering the closed network.

### Offline installation

On a connected Mac, create the portable engine bundle:

```bash
docker compose build
docker save safewhisper-engine:local | gzip -1 > safewhisper-engine-image.tar.gz
shasum -a 256 safewhisper-engine-image.tar.gz
```

Transfer `safewhisper-engine-image.tar.gz` to the offline Mac. Verify the checksum, then install without rebuilding or downloading Python packages/model weights:

```bash
docker load < safewhisper-engine-image.tar.gz
SAFEWHISPER_SKIP_DOCKER_BUILD=1 ./scripts/install.sh
```

The bundle includes the Docker base image, `faster-whisper`, `huggingface_hub`, FFmpeg, the SafeWhisper engine, and the local Whisper model. It is intentionally not committed to Git because it is several gigabytes.

## One-command macOS setup

After Docker Desktop is running:

```bash
./scripts/install.sh
```

The installer creates `~/.safewhisper/run`, builds the isolated engine, starts it with no network, installs the host helper as a LaunchAgent, builds a native `SafeWhisperMac.app` bundle with the microphone usage description, and opens it once so macOS can request the required permissions.

macOS will require explicit Microphone and Accessibility permissions. SafeWhisper does not bypass those permissions.


## Security notes

- Do not add API keys to this repository.
- Do not expose the engine on `0.0.0.0`.
- The host helper socket is mode `0600` and is never exposed on TCP.
- The helper accepts only `health` and `transcribe` requests and runs a fixed `docker exec` bridge.
- The desktop client should request macOS Microphone, Accessibility, and Input Monitoring permissions explicitly and document why.
