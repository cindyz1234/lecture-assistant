"""Compute word error rate (WER) of ASR hypotheses against reference transcripts.

Files are matched by stem: `<ref-dir>/18.06-L01.srt` pairs with
`<hyp-dir>/18.06-L01.txt`. References and hypotheses may be `.txt`, `.srt` or
`.vtt`. Prints a Markdown table ready to paste into docs/RESULTS.md.

Overall WER is corpus-level (total errors / total reference words), not the
mean of per-lecture WERs.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

import jiwer
from num2words import num2words

SUPPORTED_SUFFIXES = (".txt", ".srt", ".vtt")

_TIMESTAMP_LINE = re.compile(r"^\s*\d{1,2}:\d{2}(:\d{2})?[.,]\d{3}\s*-->")
_CUE_INDEX_LINE = re.compile(r"^\s*\d+\s*$")
# Caption conventions: "[? word ?]" is an uncertain but spoken word (kept);
# other square brackets are non-speech annotations like [LAUGHTER] (removed).
# Parentheses are left alone because they can contain speech, e.g. "A of (x)".
_UNCERTAIN = re.compile(r"\[\?\s*([^\]]*?)\s*\?\]")
_ANNOTATION = re.compile(r"\[[^\]]*\]")
_SPEAKER_LABEL = re.compile(r"^\s*[A-Z][A-Z .'-]{1,30}:\s*")  # PROFESSOR:, AUDIENCE:
_ORDINAL = re.compile(r"\b(\d+)(?:st|nd|rd|th)\b", re.I)  # 1st, 100th
_NUMBER = re.compile(r"\d+(?:\.\d+)?")
_SYMBOLS = {"%": " percent ", "+": " plus ", "=": " equals "}
# Equivalent spellings mapped to one form; applied to whole words after cleanup.
_SPELLINGS = {"okay": "ok"}
_NON_WORD = re.compile(r"[^a-z0-9' ]+")


def read_transcript(path: Path) -> str:
    """Read a transcript, stripping subtitle cue numbers, timestamps and headers."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if path.suffix.lower() not in (".srt", ".vtt"):
        return " ".join(lines)
    kept = []
    for line in lines:
        if line.strip() in ("", "WEBVTT") or _TIMESTAMP_LINE.match(line) or _CUE_INDEX_LINE.match(line):
            continue
        kept.append(_SPEAKER_LABEL.sub("", line))
    return " ".join(kept)


def _spell_number(match: re.Match[str]) -> str:
    return num2words(float(match.group()) if "." in match.group() else int(match.group()))


def normalize(text: str) -> str:
    """Normalize text so formatting differences are not counted as errors.

    Lowercases, removes [annotations], spells out numbers, ordinals and the
    symbols % + =, turns hyphens into spaces, drops other punctuation, unifies
    equivalent spellings and collapses whitespace.
    """
    text = _UNCERTAIN.sub(r" \1 ", text)
    text = _ANNOTATION.sub(" ", text)
    for symbol, words in _SYMBOLS.items():
        text = text.replace(symbol, words)
    text = _ORDINAL.sub(lambda match: f" {num2words(int(match.group(1)), to='ordinal')} ", text)
    text = _NUMBER.sub(lambda match: f" {_spell_number(match)} ", text)  # "3x" -> "three x"
    text = text.lower().replace("-", " ").replace("’", "'")
    text = _NON_WORD.sub(" ", text)
    text = re.sub(r"(?<![a-z])'|'(?![a-z])", " ", text)  # quotes, keep apostrophes in words
    return " ".join(_SPELLINGS.get(word, word) for word in text.split())


def find_transcripts(directory: Path) -> dict[str, Path]:
    return {p.stem: p for p in sorted(directory.iterdir()) if p.suffix.lower() in SUPPORTED_SUFFIXES}


def load_split(manifest: Path, split: str) -> set[str]:
    with manifest.open(newline="") as f:
        return {row["lecture_id"] for row in csv.DictReader(f) if row["split"] == split}


def evaluate(pairs: dict[str, tuple[str, str]]) -> tuple[list[tuple[str, int, float]], float]:
    """Return per-lecture (id, reference word count, WER) rows and corpus WER."""
    rows = []
    for lecture_id, (reference, hypothesis) in sorted(pairs.items()):
        rows.append((lecture_id, len(reference.split()), jiwer.wer(reference, hypothesis)))
    references = [ref for ref, _ in pairs.values()]
    hypotheses = [hyp for _, hyp in pairs.values()]
    return rows, jiwer.wer(references, hypotheses)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref-dir", type=Path, required=True)
    parser.add_argument("--hyp-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, help="restrict to lectures in --split")
    parser.add_argument("--split", default="test")
    args = parser.parse_args()

    references = find_transcripts(args.ref_dir)
    hypotheses = find_transcripts(args.hyp_dir)
    ids = references.keys() & hypotheses.keys()
    if args.manifest:
        ids &= load_split(args.manifest, args.split)
    if not ids:
        print("No matching reference/hypothesis pairs found.", file=sys.stderr)
        return 1
    for missing in sorted(references.keys() - hypotheses.keys()):
        print(f"warning: no hypothesis for {missing}", file=sys.stderr)

    pairs = {
        lecture_id: (normalize(read_transcript(references[lecture_id])),
                     normalize(read_transcript(hypotheses[lecture_id])))
        for lecture_id in ids
    }
    rows, overall = evaluate(pairs)

    print("| Lecture | Ref words | WER |")
    print("|---|---:|---:|")
    for lecture_id, word_count, wer in rows:
        print(f"| {lecture_id} | {word_count:,} | {wer:.2%} |")
    total_words = sum(count for _, count, _ in rows)
    print(f"| **Overall** | {total_words:,} | **{overall:.2%}** |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
