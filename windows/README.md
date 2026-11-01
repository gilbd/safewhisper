# SafeWhisper on Windows

The Windows client is local-first and uses the same Hebrew-tuned Whisper engine and JSON protocol as macOS.

## Current Windows architecture

```text
SafeWhisper.exe (tray client)
  - Ctrl+Alt+Shift+K: start/stop recording
  - Escape: cancel recording without transcription
  - Auto / Hebrew / English tray menu
  - local clipboard + Ctrl+V
        |
        | local AF_UNIX socket (Windows 10/11)
        v
SafeWhisper host helper
        |
        | docker exec bridge
        v
Docker Desktop: safewhisper-engine
  network_mode: none
```

No TCP listener is opened by SafeWhisper. Docker runtime remains isolated with `network_mode: none`.

## Local install on Windows 10/11

Prerequisites:

- Windows 10 1803+ or Windows 11, x64.
- Docker Desktop running.
- Python 3.11.
- Docker image `safewhisper-engine:local`, either built on a connected machine or loaded from `safewhisper-engine-image.tar.gz`.

From PowerShell in the repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install.ps1
```

The script creates `%LOCALAPPDATA%\SafeWhisper\run`, starts the isolated engine and helper, and launches the tray client.

The current Windows client uses Python dependencies from `windows/requirements.txt`. The Windows GitHub Actions workflow builds a portable `SafeWhisper.exe` artifact with PyInstaller; final microphone, hotkey, paste, and Docker validation must be run on a real Windows machine.

## Security and permissions

- No audio is sent to a cloud provider.
- The model is loaded locally inside the Docker image.
- Runtime engine networking is disabled.
- `keyboard` may require the normal Windows input permissions depending on policy and target application.
- Do not run the installer as Administrator unless the target corporate policy requires it.
