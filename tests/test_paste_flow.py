from whisperflow.core import normalize_transcript, build_paste_payload


def test_normalize_transcript_collapses_whitespace_without_destroying_hebrew():
    assert normalize_transcript("  שלום   world\n\n  היום  ") == "שלום world היום"


def test_build_paste_payload_adds_trailing_space_for_inline_paste():
    assert build_paste_payload("שלום") == "שלום "


def test_build_paste_payload_keeps_punctuation_without_extra_space():
    assert build_paste_payload("שלום.") == "שלום. "
