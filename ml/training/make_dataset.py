"""Build Whisper fine-tuning examples from lecture audio and caption files.

Consecutive caption cues are grouped into clips of at most 30 seconds (Whisper's
input window). Each clip is a line in a JSONL manifest of {audio, start, end,
text, cues, lecture_id}: `audio` is the full 16 kHz lecture WAV and start/end
locate the clip in it, so no audio is copied (~100 MB saved per lecture).
`cues` holds [start, end, text] relative to the clip start, for timestamped
targets.

    python3 ml/training/make_dataset.py --split train --split dev

Writes ml/data/clips/<split>.jsonl.
Clip text keeps the captions' casing and punctuation (Whisper outputs formatted
text); speaker labels and non-speech annotations are removed.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import wave
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "ml/data/manifest.csv"
RAW_DIR = ROOT / "ml/data/raw"
PROCESSED_DIR = ROOT / "ml/data/processed"
CLIPS_DIR = ROOT / "ml/data/clips"

MAX_CLIP_SECONDS = 30.0
PADDING_SECONDS = 0.2

_CUE_TIME = re.compile(r"^\s*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{3})")
_SPEAKER_LABEL = re.compile(r"^\s*[A-Z][A-Z .'-]{1,30}:\s*")
_UNCERTAIN = re.compile(r"\[\?\s*([^\]]*?)\s*\?\]")
_ANNOTATION = re.compile(r"\[[^\]]*\]")


@dataclass(frozen=True)
class Cue:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class Clip:
    start: float
    end: float
    text: str
    cues: tuple[Cue, ...]


def _seconds(hours: str | None, minutes: str, seconds: str, millis: str) -> float:
    return int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds) + int(millis) / 1000


def clean_caption_text(text: str) -> str:
    """Remove speaker labels and non-speech annotations; keep uncertain words."""
    text = _SPEAKER_LABEL.sub("", text)
    text = _UNCERTAIN.sub(r"\1", text)
    text = _ANNOTATION.sub(" ", text)
    return " ".join(text.split())


def parse_vtt(content: str) -> list[Cue]:
    """Parse WebVTT/SRT cues. Multi-line cue text is joined; empty cues are dropped."""
    cues: list[Cue] = []
    timing: tuple[float, float] | None = None
    lines: list[str] = []

    def flush() -> None:
        if timing is not None:
            text = " ".join(clean_caption_text(line) for line in lines)
            text = " ".join(text.split())
            if text:
                cues.append(Cue(timing[0], timing[1], text))

    for line in content.splitlines():
        match = _CUE_TIME.match(line)
        if match:
            flush()
            g = match.groups()
            timing = (_seconds(*g[0:4]), _seconds(*g[4:8]))
            lines = []
        elif not line.strip():
            flush()
            timing, lines = None, []
        elif timing is not None:
            lines.append(line)
    flush()
    return cues


def group_cues(cues: list[Cue], max_seconds: float = MAX_CLIP_SECONDS) -> list[Clip]:
    """Group consecutive cues into clips no longer than `max_seconds`.

    A single cue longer than `max_seconds` is dropped: it can't be split without
    knowing where its words fall, and Whisper can't take more than 30 s.
    """
    clips: list[Clip] = []
    current: list[Cue] = []

    def flush() -> None:
        if current:
            clips.append(Clip(current[0].start, current[-1].end, " ".join(c.text for c in current), tuple(current)))

    for cue in sorted(cues, key=lambda c: c.start):
        if cue.end - cue.start > max_seconds:
            flush()
            current = []
            continue
        if current and cue.end - current[0].start > max_seconds:
            flush()
            current = []
        current.append(cue)
    flush()
    return clips


def relative_cues(clip: Clip, audio_start: float, audio_end: float) -> list[list[float | str]]:
    """Cue times relative to the clip's audio (which includes padding), clamped to it."""
    length = audio_end - audio_start
    return [
        [round(min(max(cue.start - audio_start, 0.0), length), 2),
         round(min(max(cue.end - audio_start, 0.0), length), 2),
         cue.text]
        for cue in clip.cues
    ]


def read_clip(path: Path, start: float, end: float) -> bytes:
    """16-bit PCM frames for [start, end) seconds of a WAV file."""
    with wave.open(str(path), "rb") as source:
        rate = source.getframerate()
        first = max(0, int(start * rate))
        last = min(source.getnframes(), int(end * rate))
        source.setpos(first)
        return source.readframes(max(0, last - first))


def lectures_in(splits: list[str]) -> list[dict[str, str]]:
    with MANIFEST.open(newline="") as f:
        return [row for row in csv.DictReader(f) if row["split"] in splits]


def build_split(split: str) -> tuple[int, float]:
    """Writes clips and the JSONL manifest for one split; returns (clips, hours)."""
    manifest_path = CLIPS_DIR / f"{split}.jsonl"
    count, seconds = 0, 0.0
    CLIPS_DIR.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w") as manifest:
        for row in lectures_in([split]):
            lecture_id = row["lecture_id"]
            captions = next(iter(sorted(RAW_DIR.glob(f"{lecture_id}.vtt"))), None)
            audio = PROCESSED_DIR / f"{lecture_id}.wav"
            if captions is None or not audio.exists():
                print(f"  {lecture_id}: missing captions or audio, skipped (run download.py)", file=sys.stderr)
                continue
            clips = group_cues(parse_vtt(captions.read_text(encoding="utf-8", errors="replace")))
            with wave.open(str(audio), "rb") as source:
                duration = source.getnframes() / source.getframerate()
            for clip in clips:
                start = max(0.0, clip.start - PADDING_SECONDS)
                end = min(duration, clip.end + PADDING_SECONDS, start + MAX_CLIP_SECONDS)
                manifest.write(json.dumps({
                    "audio": str(audio.relative_to(ROOT)),
                    "start": round(start, 3),
                    "end": round(end, 3),
                    "text": clip.text,
                    "cues": relative_cues(clip, start, end),
                    "lecture_id": lecture_id,
                }) + "\n")
                count += 1
                seconds += end - start
            print(f"  {lecture_id}: {len(clips)} clips")
    return count, seconds / 3600


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--split", action="append", choices=["train", "dev"], required=True,
                        help="split to build (repeatable). The test split is never used for training.")
    args = parser.parse_args()
    for split in args.split:
        print(split)
        count, hours = build_split(split)
        print(f"{split}: {count} clips, {hours:.2f} hours -> {CLIPS_DIR / (split + '.jsonl')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
