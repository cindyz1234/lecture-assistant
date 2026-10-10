"""Download lectures listed in manifest.csv and extract 16 kHz mono WAV audio.

Only direct downloads from allow-listed hosts (MIT OpenCourseWare and the
Internet Archive, which hosts many OCW videos) are permitted. YouTube and other
sites whose terms prohibit downloading are rejected.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

DATA_DIR = Path(__file__).resolve().parent
MANIFEST = DATA_DIR / "manifest.csv"
RAW_DIR = DATA_DIR / "raw"
PROCESSED_DIR = DATA_DIR / "processed"

ALLOWED_HOSTS = ("ocw.mit.edu", "archive.org")
ALLOWED_LICENSE_PREFIX = "CC BY-NC-SA"


def is_allowed_url(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return urlparse(url).scheme == "https" and any(
        host == allowed or host.endswith("." + allowed) for allowed in ALLOWED_HOSTS
    )


def validate_row(row: dict[str, str]) -> list[str]:
    """Return a list of problems with a manifest row (empty if valid)."""
    problems = []
    if not row["license"].strip().upper().startswith(ALLOWED_LICENSE_PREFIX):
        problems.append(f"license {row['license']!r} is not {ALLOWED_LICENSE_PREFIX}")
    if row["split"] not in ("train", "dev", "test"):
        problems.append(f"split {row['split']!r} must be train, dev or test")
    for column in ("video_url", "transcript_url"):
        url = row[column].strip()
        if url and not is_allowed_url(url):
            problems.append(f"{column} host is not allow-listed: {url}")
    if not row["video_url"].strip():
        problems.append("video_url is empty")
    return problems


def download(url: str, destination: Path) -> None:
    if destination.exists():
        print(f"  exists, skipping: {destination.name}")
        return
    print(f"  downloading {url}")
    partial = destination.with_suffix(destination.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "lecture-assistant-research/0.1"})
    with urllib.request.urlopen(request) as response, partial.open("wb") as out:
        shutil.copyfileobj(response, out)
    partial.rename(destination)


def extract_audio(video: Path, wav: Path) -> None:
    if wav.exists():
        print(f"  exists, skipping: {wav.name}")
        return
    print(f"  extracting audio -> {wav.name}")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(video),
         "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)],
        check=True,
    )


def url_suffix(url: str, default: str) -> str:
    return Path(urlparse(url).path).suffix.lower() or default


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--split", choices=["train", "dev", "test"])
    args = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found on PATH", file=sys.stderr)
        return 1

    with args.manifest.open(newline="") as f:
        rows = [row for row in csv.DictReader(f) if not args.split or row["split"] == args.split]

    invalid = {row["lecture_id"]: validate_row(row) for row in rows}
    invalid = {k: v for k, v in invalid.items() if v}
    if invalid:
        for lecture_id, problems in invalid.items():
            print(f"{lecture_id}: " + "; ".join(problems), file=sys.stderr)
        return 1

    RAW_DIR.mkdir(exist_ok=True)
    PROCESSED_DIR.mkdir(exist_ok=True)
    for row in rows:
        lecture_id = row["lecture_id"]
        print(lecture_id)
        video = RAW_DIR / f"{lecture_id}{url_suffix(row['video_url'], '.mp4')}"
        download(row["video_url"], video)
        if row["transcript_url"].strip():
            download(row["transcript_url"], RAW_DIR / f"{lecture_id}{url_suffix(row['transcript_url'], '.txt')}")
        extract_audio(video, PROCESSED_DIR / f"{lecture_id}.wav")

    print(f"Done: {len(rows)} lecture(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
