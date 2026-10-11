"""Technical-term recall: of the term occurrences in the reference, how many the
hypothesis also contains.

WER weighs every word equally, so it barely moves when a model learns domain
vocabulary ("Bohr", "radial"). Term recall isolates exactly that.

For each lecture and term, matched = min(reference count, hypothesis count);
recall = sum(matched) / sum(reference count). Counts are taken on text
normalized like WER (wer.normalize), with an optional plural "s"/"es".

    python3 ml/eval/term_recall.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en \\
        --manifest ml/data/manifest.csv --split test
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

from wer import find_transcripts, load_split, normalize, read_transcript, select_lectures

TERMS = Path(__file__).resolve().parent / "terms.txt"


def load_terms(path: Path = TERMS) -> list[str]:
    terms = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            terms.append(normalize(line))
    return list(dict.fromkeys(terms))  # dedupe, keep order


def count_terms(text: str, terms: list[str]) -> Counter[str]:
    """Occurrences of each term in normalized `text` (whole words, optional plural)."""
    counts: Counter[str] = Counter()
    for term in terms:
        pattern = rf"(?<![a-z0-9']){re.escape(term)}(?:s|es)?(?![a-z0-9'])"
        if found := len(re.findall(pattern, text)):
            counts[term] = found
    return counts


def term_recall(reference: str, hypothesis: str, terms: list[str]) -> tuple[int, int, Counter[str]]:
    """Returns (matched, total, missed-per-term) for normalized texts."""
    ref_counts = count_terms(reference, terms)
    hyp_counts = count_terms(hypothesis, terms)
    matched = sum(min(count, hyp_counts[term]) for term, count in ref_counts.items())
    missed = Counter({term: count - min(count, hyp_counts[term]) for term, count in ref_counts.items()})
    return matched, sum(ref_counts.values()), +missed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref-dir", type=Path, required=True)
    parser.add_argument("--hyp-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--split", default="test")
    parser.add_argument("--terms", type=Path, default=TERMS)
    args = parser.parse_args()

    terms = load_terms(args.terms)
    references = find_transcripts(args.ref_dir)
    hypotheses = find_transcripts(args.hyp_dir)
    split = load_split(args.manifest, args.split) if args.manifest else None
    ids, missing = select_lectures(set(references), set(hypotheses), split)
    for lecture_id in sorted(missing):
        print(f"warning: no hypothesis for {lecture_id}", file=sys.stderr)
    if not ids:
        print("No matching reference/hypothesis pairs found.", file=sys.stderr)
        return 1

    print("| Lecture | Term occurrences | Term recall | Most missed |")
    print("|---|---:|---:|---|")
    total_matched = total = 0
    for lecture_id in sorted(ids):
        matched, count, missed = term_recall(
            normalize(read_transcript(references[lecture_id])),
            normalize(read_transcript(hypotheses[lecture_id])),
            terms,
        )
        total_matched += matched
        total += count
        worst = ", ".join(f"{term} ({n})" for term, n in missed.most_common(3)) or "-"
        print(f"| {lecture_id} | {count} | {matched / count:.1%} | {worst} |" if count else f"| {lecture_id} | 0 | - | - |")
    print(f"| **Overall** | {total} | **{total_matched / total:.1%}** | |" if total else "| **Overall** | 0 | - | |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
