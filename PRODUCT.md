# SafeWhisper product requirements

## User story

A user working in any desktop app holds a global hotkey, speaks in Hebrew or English, releases the key, and gets the transcript pasted at the active cursor. The transcript is also available in the clipboard.

## MVP acceptance criteria

- [ ] A global hotkey starts and stops recording from any focused application.
- [ ] Recording never leaves the workstation for transcription.
- [ ] Hebrew, English, and mixed Hebrew-English speech are supported.
- [ ] The engine runs without network access at runtime.
- [ ] The transcript is normalized conservatively: no translation, no summarization, no silent rewriting.
- [ ] The result is copied to the clipboard.
- [ ] The result is pasted into the previously focused application.
- [ ] Temporary audio is deleted after transcription.
- [ ] If the engine is unavailable, the UI shows a recoverable error and does not lose clipboard contents.
- [ ] Installation documents microphone, accessibility, and input-monitoring permissions.

## Closed-network distribution

The connected build machine:

1. Builds the Docker image and downloads the pinned model.
2. Runs unit and integration tests.
3. Exports the image or pushes it to the approved internal registry.

The closed-network workstation:

1. Imports the signed image or pulls it from the approved registry.
2. Starts the engine with `network_mode: none`.
3. Starts the macOS desktop agent.
4. Does not need Hugging Face, OpenAI, or any external speech service.

## Threat model

- No TCP listener for the engine.
- Unix socket permissions restrict local access.
- Container drops capabilities and uses a read-only root filesystem.
- Audio exists only in memory and a container tmpfs during inference.
- Model is pinned by repository and image digest in production documentation.
- Desktop permissions are explicit and revocable through macOS settings.
