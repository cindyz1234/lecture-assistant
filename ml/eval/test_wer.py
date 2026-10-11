from pathlib import Path

import pytest

from wer import evaluate, normalize, read_transcript, select_lectures


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("Hello, World!", "hello world"),
        ("We have 3 vectors.", "we have three vectors"),
        ("Eigen-values [LAUGHTER] of A", "eigen values of a"),
        ("A of (x) equals [INAUDIBLE] zero", "a of x equals zero"),
        ("these [? functions ?] are smooth", "these functions are smooth"),
        ("plus 3x equals 2", "plus three x equals two"),
        ("u to the 100th power, the 1st and 2nd", "u to the one hundredth power the first and second"),
        ("Okay, so x + y = 1", "ok so x plus y equals one"),
        ("The Schrödinger equation, naïve café", "the schrodinger equation naive cafe"),
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


def test_read_captions_strips_speaker_labels(tmp_path: Path) -> None:
    vtt = tmp_path / "lecture.vtt"
    vtt.write_text(
        "WEBVTT\n\n00:00.000 --> 00:02.000\nPROFESSOR: What's the energy?\n\n"
        "00:02.000 --> 00:04.000\nAUDIENCE: Zero.\n\n"
        "00:04.000 --> 00:06.000\nSTUDENT: The ground state.\n"
    )
    assert read_transcript(vtt) == "What's the energy? Zero. The ground state."


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


def test_only_lectures_in_the_split_count_as_missing() -> None:
    references = {"test-a", "test-b", "train-a"}
    hypotheses = {"test-a"}

    assert select_lectures(references, hypotheses, {"test-a", "test-b"}) == ({"test-a"}, {"test-b"})
    assert select_lectures(references, hypotheses, None) == ({"test-a"}, {"test-b", "train-a"})
