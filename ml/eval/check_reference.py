"""Check reference transcripts for out-of-order (spliced) text.

Some OCW caption files splice text from one part of a lecture into another.
A model's transcript of the audio then contains the same passages at different
positions, so WER counts them twice (as deletions and insertions) and the
lecture's WER is inflated by the reference, not the model.

This script aligns each reference with a hypothesis and counts reference words
in long unmatched runs (deleted or substituted) whose text appears verbatim
elsewhere in the hypothesis ("displaced" words). It measures the reference's word order, not the model's
accuracy: genuine recognition errors are not found verbatim elsewhere.

    python3 ml/eval/check_reference.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import jiwer

from wer import find_transcripts, normalize, read_transcript

MIN_RUN_WORDS = 8
MAX_DISPLACED_FRACTION = 0.01


def displaced_fraction(reference: str, hypothesis: str, min_run: int = MIN_RUN_WORDS) -> float:
    """Fraction of reference words in unmatched runs found verbatim elsewhere in the hypothesis."""
    ref_words = reference.split()
    if not ref_words:
        return 0.0
    padded_hypothesis = f" {hypothesis} "
    alignment = jiwer.process_words(reference, hypothesis).alignments[0]
    displaced = 0
    for chunk in alignment:
        length = chunk.ref_end_idx - chunk.ref_start_idx
        # The aligner may record a moved passage as deletions or as substitutions.
        if chunk.type not in ("delete", "substitute") or length < min_run:
            continue
        # Look for any min_run-word window of the unmatched run elsewhere in the hypothesis.
        run = ref_words[chunk.ref_start_idx:chunk.ref_end_idx]
        windows = (" ".join(run[i:i + min_run]) for i in range(0, length - min_run + 1, min_run))
        if any(f" {window} " in padded_hypothesis for window in windows):
            displaced += length
    return displaced / len(ref_words)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref-dir", type=Path, required=True)
    parser.add_argument("--hyp-dir", type=Path, required=True)
    parser.add_argument("--threshold", type=float, default=MAX_DISPLACED_FRACTION)
    args = parser.parse_args()

    references = find_transcripts(args.ref_dir)
    hypotheses = find_transcripts(args.hyp_dir)
    failed = False
    for lecture_id in sorted(references.keys() & hypotheses.keys()):
        fraction = displaced_fraction(
            normalize(read_transcript(references[lecture_id])),
            normalize(read_transcript(hypotheses[lecture_id])),
        )
        ok = fraction <= args.threshold
        failed |= not ok
        print(f"{lecture_id}: {fraction:.1%} displaced -> {'ok' if ok else 'REFERENCE LOOKS CORRUPTED'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
