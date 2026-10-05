# SafeWhisper

Local-first Hebrew + English speech-to-text for macOS.

SafeWhisper is designed for closed corporate networks:

- Global hotkey starts/stops recording.
- Audio is transcribed by a local `faster-whisper` engine.
- The engine runs in Docker with `network_mode: none`.
- The host app talks to the engine through a Unix socket, not TCP.
- Transcript is copied to the clipboard and pasted into the active app.
- No audio or transcript is sent to a cloud transcription provider.

## Architecture

```text
[macOS hotkey + recorder]
          |
          | Unix socket
          v
[Docker: safewhisper-engine]
  network: none
  ivrit-ai/whisper-large-v3-turbo-ct2
          |
          v
[clipboard + paste]
```

The model is downloaded only during `docker build`. Runtime has no network namespace. The container has a read-only root filesystem, a small tmpfs for transient audio, no Linux capabilities, and no-new-privileges enabled.

## Build and run

```bash
docker compose build
docker compose up -d
```

The first build downloads the model and is large. Do it on a connected machine, then export/import the image or publish it to the company's approved registry before entering the closed network.

## Current status

The repository currently contains the isolated engine protocol and container boundary. The next vertical slice adds the native macOS recorder, global hotkey, clipboard, and paste integration.

## Security notes

- Do not add API keys to this repository.
- Do not expose the engine on `0.0.0.0`.
- The Unix socket is the only runtime boundary.
- The desktop client should request macOS Microphone, Accessibility, and Input Monitoring permissions explicitly and document why.
