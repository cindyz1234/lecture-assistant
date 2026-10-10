from pathlib import Path

import pytest

from wer import evaluate, normalize, read_transcript


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Hello, World!", "hello world"),
        ("We have 3 vectors.", "we have three vectors"),
        ("Eigen-values [LAUGHTER] of A", "eigen values of a"),
        ("It's 50% done", "it's fifty percent done"),
        ("  extra   spaces  ", "extra spaces"),
    ],
)
def test_normalize(raw: str, expected: str) -> None:
    assert normalize(raw) == expected


def test_read_srt_strips_cues_and_timestamps(tmp_path: Path) -> None:
    srt = tmp_path / "lecture.srt"
    srt.write_text(
        "1\n00:00:00,000 --> 00:00:02,500\nOkay, let's start.\n\n"
        "2\n00:00:02,500 --> 00:00:05,000\nToday: matrices.\n"
    )
    assert read_transcript(srt) == "Okay, let's start. Today: matrices."


def test_read_vtt_strips_header(tmp_path: Path) -> None:
    vtt = tmp_path / "lecture.vtt"
    vtt.write_text("WEBVTT\n\n00:00.000 --> 00:02.000\nHello there\n")
    assert read_transcript(vtt) == "Hello there"


def test_overall_wer_is_corpus_level() -> None:
    pairs = {
        "short": ("one two", "one three"),  # 1 error / 2 words
        "long": ("a b c d e f g h", "a b c d e f g h"),  # 0 errors / 8 words
    }
    rows, overall = evaluate(pairs)
    assert [row[2] for row in rows] == [0.0, 0.5]  # sorted by id: long, short
    assert overall == pytest.approx(1 / 10)
