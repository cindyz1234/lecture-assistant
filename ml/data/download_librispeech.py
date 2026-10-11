"""Download a fixed subset of LibriSpeech test-clean for a general-speech check.

Fine-tuning on lectures can make a model worse at ordinary speech ("catastrophic
forgetting"), which the lecture test set wouldn't show. LibriSpeech test-clean
(read English audiobooks, CC BY 4.0, https://www.openslr.org/12) is the
standard check.

Writes, for a deterministic subset (every Nth utterance by sorted ID):
- ml/data/processed/librispeech/<utterance id>.wav   16 kHz mono
- ml/data/raw/librispeech/<utterance id>.txt         reference transcript

    python3 ml/data/download_librispeech.py --count 300
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

from netutil import urlopen

DATA_DIR = Path(__file__).resolve().parent
ARCHIVE_URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
ARCHIVE = DATA_DIR / "raw" / "librispeech-test-clean.tar.gz"
AUDIO_DIR = DATA_DIR / "processed" / "librispeech"
TEXT_DIR = DATA_DIR / "raw" / "librispeech"


def read_transcripts(archive: tarfile.TarFile) -> dict[str, tuple[str, tarfile.TarInfo]]:
    """Maps utterance ID -> (transcript, FLAC member) for the whole archive."""
    members = {Path(m.name).stem: m for m in archive.getmembers() if m.name.endswith(".flac")}
    transcripts: dict[str, tuple[str, tarfile.TarInfo]] = {}
    for member in archive.getmembers():
        if not member.name.endswith(".trans.txt"):
            continue
        for line in archive.extractfile(member).read().decode().splitlines():
            utterance_id, _, text = line.partition(" ")
            if utterance_id in members:
                transcripts[utterance_id] = (text.strip(), members[utterance_id])
    return transcripts


def every_nth(ids: list[str], count: int) -> list[str]:
    """`count` IDs spread evenly over the sorted list (deterministic, no hand-picking)."""
    ids = sorted(ids)
    if count >= len(ids):
        return ids
    return [ids[i * len(ids) // count] for i in range(count)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=300)
    args = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found on PATH", file=sys.stderr)
        return 1
    if not ARCHIVE.exists():
        ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
        print(f"downloading {ARCHIVE_URL}")
        partial = ARCHIVE.with_suffix(".part")
        with urlopen(ARCHIVE_URL, timeout=120) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
        partial.rename(ARCHIVE)

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    TEXT_DIR.mkdir(parents=True, exist_ok=True)
    with tarfile.open(ARCHIVE) as archive:
        transcripts = read_transcripts(archive)
        chosen = every_nth(list(transcripts), args.count)
        seconds = 0.0
        for utterance_id in chosen:
            text, member = transcripts[utterance_id]
            (TEXT_DIR / f"{utterance_id}.txt").write_text(text + "\n")
            wav = AUDIO_DIR / f"{utterance_id}.wav"
            if not wav.exists():
                flac = archive.extractfile(member).read()
                subprocess.run(
                    ["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "flac", "-i", "pipe:0",
                     "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)],
                    input=flac, check=True,
                )
            seconds += (wav.stat().st_size - 44) / 32_000
    print(f"{len(chosen)} utterances, {seconds / 60:.1f} minutes -> {AUDIO_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
