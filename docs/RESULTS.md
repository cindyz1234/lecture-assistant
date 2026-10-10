# Results

Measure before optimizing. Every row records how it was measured so it can be reproduced.

## ASR word error rate (test split)

Produced by `python3 ml/eval/wer.py --ref-dir … --hyp-dir … --manifest ml/data/manifest.csv`.

| Model | Size | Overall WER | Term recall | Commit | Date |
|---|---:|---:|---:|---|---|
| Whisper (baseline, TBD) | | | | | |

## On-device performance

| Model | Device | Compute | RTF | Caption latency | Peak memory | Commit | Date |
|---|---|---|---:|---:|---:|---|---|
| Whisper base.en (WhisperKit 1.1.0) | M-series Mac (dev) | default | 0.09 | n/a | | uncommitted | 2026-10-09 |

The first row is a smoke test on a 16 s synthetic (`say`) clip, release build, 30 s windows. It is not the baseline; re-measure on OCW lectures and on iPhone.

RTF (real-time factor) = processing time / audio duration. Lower is better; target < 0.3.
