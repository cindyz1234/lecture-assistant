# Results

Measure before optimizing. Every row records how it was measured so it can be reproduced.

## ASR word error rate (test split)

Test split: 3 OCW lectures from 3 subjects, 28,414 reference words (see
[ml/data/README.md](../ml/data/README.md)). References are OCW's caption files.
Scored with `ml/eval/wer.py`; the normalization rules are frozen as of this
baseline, so changing them requires re-scoring every model.

```sh
Tools/.build/release/transcribe --model base.en --out ml/eval/outputs/base.en ml/data/processed/*.wav
python3 ml/eval/check_reference.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en
python3 ml/eval/wer.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en \
    --manifest ml/data/manifest.csv --split test
```

| Model | Size | 18.06 (math) | 5.111 (chem) | 8.04 (physics) | **Overall WER** | Term recall | Date |
|---|---:|---:|---:|---:|---:|---:|---|
| Whisper base.en (WhisperKit 1.1.0, 30 s windows) | 142 MB | 8.99% | 4.10% | 7.13% | **6.62%** | not yet measured | 2026-10-10 |

### Baseline error analysis (base.en)

The most frequent substitutions fall into three groups:

- **Domain vocabulary (what fine-tuning should fix):** radial → "radio",
  Bohr → "bore", and math notation such as F_k → "fk", u_k → "plus".
- **Notation formatting:** p_x written as "px" vs. "p x"; not obviously an
  error, but counted as one.
- **Reference errors (the model was right):** "discreet" (should be
  *discrete*), "principle quantum number" (should be *principal*).
  References are not edited, so these errors count against every model equally.

Math has the highest WER: dense notation spoken as letters ("A k", "lambda one").

## On-device performance

RTF (real-time factor) = processing time / audio duration. Lower is better; target < 0.3.

| Model | Device | Audio | RTF | Caption latency | Peak memory | Date |
|---|---|---|---:|---:|---:|---|
| Whisper base.en | Mac15,6 (dev Mac), release build | 3 test lectures, 3 h 2 min | 0.020–0.025 | n/a | not measured | 2026-10-10 |

A 50-minute lecture transcribes in about one minute on the Mac. Model load
(after download) takes about 15 s. iPhone numbers still to be measured.
