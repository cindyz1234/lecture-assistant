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
import time
import urllib.error
from pathlib import Path
from urllib.parse import urlparse

from netutil import urlopen

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


def download(url: str, destination: Path, attempts: int = 4) -> None:
    if destination.exists():
        print(f"  exists, skipping: {destination.name}")
        return
    print(f"  downloading {url}")
    partial = destination.with_suffix(destination.suffix + ".part")
    for attempt in range(1, attempts + 1):
        try:
            with urlopen(url) as response, partial.open("wb") as out:
                shutil.copyfileobj(response, out)
            break
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            # Retry server errors (5xx) and network failures; client errors (4xx) won't fix themselves.
            is_client_error = isinstance(error, urllib.error.HTTPError) and error.code < 500
            if is_client_error or attempt == attempts:
                raise
            delay = 5 * 2 ** (attempt - 1)
            print(f"  {error}; retrying in {delay}s ({attempt}/{attempts - 1})")
            time.sleep(delay)
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


def fetch_lecture(row: dict[str, str], delete_video: bool) -> None:
    """Downloads captions and audio for one lecture, skipping what already exists.

    The video is only needed to extract audio, so it isn't downloaded when the
    WAV exists, and with `delete_video` it is removed after extraction.
    """
    lecture_id = row["lecture_id"]
    print(lecture_id)
    if row["transcript_url"].strip():
        download(row["transcript_url"], RAW_DIR / f"{lecture_id}{url_suffix(row['transcript_url'], '.txt')}")
    wav = PROCESSED_DIR / f"{lecture_id}.wav"
    video = RAW_DIR / f"{lecture_id}{url_suffix(row['video_url'], '.mp4')}"
    if wav.exists():
        print(f"  exists, skipping: {wav.name}")
    else:
        download(row["video_url"], video)
        extract_audio(video, wav)
    if delete_video and video.exists():
        video.unlink()
        print(f"  deleted {video.name}")


def url_suffix(url: str, default: str) -> str:
    return Path(urlparse(url).path).suffix.lower() or default


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--split", choices=["train", "dev", "test"])
    parser.add_argument("--delete-video", action="store_true",
                        help="delete each video after extracting its audio (saves ~100-250 MB per lecture)")
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
        fetch_lecture(row, delete_video=args.delete_video)

    print(f"Done: {len(rows)} lecture(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
