import wave
from pathlib import Path

from make_dataset import Clip, Cue, clean_caption_text, group_cues, parse_vtt, read_clip, relative_cues

VTT = """WEBVTT

00:00:01.000 --> 00:00:04.500
PROFESSOR: So today we talk
about eigenvalues.

00:00:04.500 --> 00:00:06.000
[LAUGHTER]

00:00:06.000 --> 00:00:09.250
These [? functions ?] are smooth.

01:02:03.000 --> 01:02:05.000
AUDIENCE: Why?
"""


def test_parse_vtt_cleans_text_and_drops_empty_cues() -> None:
    assert parse_vtt(VTT) == [
        Cue(1.0, 4.5, "So today we talk about eigenvalues."),
        Cue(6.0, 9.25, "These functions are smooth."),
        Cue(3723.0, 3725.0, "Why?"),
    ]


def test_clean_caption_text_keeps_casing_and_punctuation() -> None:
    assert clean_caption_text("STUDENT: Is A^2 = 0? [INAUDIBLE]") == "Is A^2 = 0?"


def test_group_cues_respects_max_length() -> None:
    cues = [Cue(float(i * 10), float(i * 10 + 9), f"cue{i}") for i in range(7)]  # 9 s cues, 10 s apart

    clips = group_cues(cues, max_seconds=30)

    assert [c.text for c in clips] == ["cue0 cue1 cue2", "cue3 cue4 cue5", "cue6"]
    assert all(c.end - c.start <= 30 for c in clips)
    assert (clips[0].start, clips[0].end) == (0.0, 29.0)


def test_relative_cues_are_offset_and_clamped_to_the_clip_audio() -> None:
    cues = (Cue(10.1, 12.0, "first"), Cue(12.0, 39.95, "last"))
    clip = Clip(10.1, 39.95, "first last", cues)

    # Audio was cut from 9.9 s (0.2 s padding) to 39.9 s (30 s maximum).
    assert relative_cues(clip, 9.9, 39.9) == [[0.2, 2.1, "first"], [2.1, 30.0, "last"]]


def test_group_cues_drops_cues_longer_than_max() -> None:
    cues = [Cue(0, 5, "short"), Cue(5, 45, "too long"), Cue(45, 50, "after")]

    assert [c.text for c in group_cues(cues, max_seconds=30)] == ["short", "after"]


def test_read_clip_returns_the_requested_range(tmp_path: Path) -> None:
    source_path = tmp_path / "lecture.wav"
    with wave.open(str(source_path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16_000)
        out.writeframes(bytes(range(256)) * 250)  # 64,000 bytes = 2 s of 16-bit audio

    frames = read_clip(source_path, 0.5, 1.25)

    assert len(frames) == 12_000 * 2  # 0.75 s of 16-bit samples
    assert frames[:2] == (bytes(range(256)) * 250)[16_000:16_002]
    assert read_clip(source_path, 1.9, 5.0) == (bytes(range(256)) * 250)[60_800:]  # clamped at the end
