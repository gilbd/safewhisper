"""Language mode validation shared by the engine protocol."""
from __future__ import annotations

SUPPORTED_LANGUAGES = {"he", "en"}


def requested_language(request: dict) -> str | None:
    """Return the Whisper language override, or None for automatic detection."""
    value = request.get("language")
    if value in (None, "", "auto"):
        return None
    if value not in SUPPORTED_LANGUAGES:
        raise ValueError(f"unsupported language: {value}")
    return value
