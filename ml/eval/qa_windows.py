"""Print evenly spaced caption windows for writing Q&A evaluation questions.

To avoid cherry-picking, questions are written for fixed moments: for each
lecture, `--per-lecture` moments at (2i + 1) / (2n) of its length, each with the
reference captions within ±`--radius` seconds.

    python3 ml/eval/qa_windows.py --split dev --split test > /tmp/windows.txt
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml/training"))

from make_dataset import parse_vtt  # noqa: E402


def moments(duration: float, count: int) -> list[float]:
    """`count` evenly spaced times, centered in equal slices of `duration`."""
    return [duration * (2 * i + 1) / (2 * count) for i in range(count)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--split", action="append", required=True, choices=["dev", "test"])
    parser.add_argument("--per-lecture", type=int, default=15)
    parser.add_argument("--radius", type=float, default=30.0)
    args = parser.parse_args()

    with (ROOT / "ml/data/manifest.csv").open(newline="") as f:
        lectures = [row for row in csv.DictReader(f) if row["split"] in args.split]
    for row in lectures:
        cues = parse_vtt((ROOT / "ml/data/raw" / f"{row['lecture_id']}.vtt").read_text(encoding="utf-8", errors="replace"))
        for i, moment in enumerate(moments(cues[-1].end, args.per_lecture)):
            start, end = moment - args.radius, moment + args.radius
            text = " ".join(c.text for c in cues if c.end > start and c.start < end)
            print(f"## {row['lecture_id']} #{i:02d} [{row['split']}] {start:.0f}-{end:.0f}s\n{text}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
