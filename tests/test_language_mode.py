from safewhisper.language import requested_language


def test_auto_language_is_passed_to_whisper_as_none():
    assert requested_language({"language": "auto"}) is None
    assert requested_language({}) is None


def test_explicit_language_is_preserved():
    assert requested_language({"language": "he"}) == "he"
    assert requested_language({"language": "en"}) == "en"


def test_unknown_language_is_rejected():
    try:
        requested_language({"language": "fr"})
    except ValueError as exc:
        assert "unsupported language" in str(exc)
    else:
        raise AssertionError("unsupported language was accepted")
