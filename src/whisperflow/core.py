"""Pure text handling shared by the desktop client and engine boundary."""


def normalize_transcript(text: str) -> str:
    """Collapse transcription whitespace while preserving words and punctuation."""
    return " ".join(text.split())


def build_paste_payload(text: str) -> str:
    """Return text suitable for inline paste without changing user content."""
    normalized = normalize_transcript(text)
    return f"{normalized} " if normalized else ""
