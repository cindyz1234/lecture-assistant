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

### Run-to-run variation and temperature fallback

Re-running the same model on the same audio gave different results. WhisperKit
retries low-confidence windows with random sampling ("temperature fallback");
turning it off makes runs identical but much worse (2026-10-11):

| Decoding | Run | 18.06 | 5.111 | 8.04 | Overall | Identical runs? |
|---|---|---:|---:|---:|---:|---|
| Fallback on (default, as in the app) | 1 | 8.99% | 4.10% | 7.13% | 6.62% | no |
| | 2 | 10.08% | 4.13% | 7.21% | 6.90% | |
| Fallback off | 1 | 13.41% | 4.09% | 10.16% | 9.03% | yes |
| | 2 | 13.41% | 4.09% | 10.16% | 9.03% | |

Fallback rescues windows where decoding fails (mostly 18.06 and 8.04), so the
app keeps it on. **Models are compared with fallback on, as the mean of 3 runs**;
the fallback-off score is reported as a secondary, exactly repeatable metric.

### Technical-term recall

`ml/eval/term_recall.py` with `ml/eval/terms.txt` (65 terms chosen from the
courses' syllabus topics, not from model errors). base.en, fallback on, run 2:

| Lecture | Term occurrences | Term recall | Most missed |
|---|---:|---:|---|
| 18.06 L22 | 233 | 97.4% | eigenvector (2), determinant (2) |
| 5.111 L6 | 373 | 97.3% | bohr (5), radial (5) |
| 8.04 L6 | 438 | 93.4% | schrodinger (15: "Schrader", "Schreini", …), eigenfunction (6) |
| **Overall** | 1,044 | **95.7%** | |

## Fine-tuning Whisper base.en (v1, Mac)

Fine-tuned `openai/whisper-base.en` on the 8 training lectures (957 clips,
7.4 h, timestamped caption targets) on the Mac GPU: 4 epochs, lr 1e-5 with
warm-up and linear decay, effective batch 16, encoder conv front end frozen.
27 minutes. Best epoch chosen by dev WER (7.016 L4). Both models were converted
with the same `ml/training/export_coreml.sh` and run through the app pipeline
(`transcribe`, fallback on), 3 runs each.

| Metric | Stock base.en (our conversion) | Fine-tuned v1 |
|---|---:|---:|
| Test WER, mean of 3 (range) | **7.24%** (7.12–7.36) | 7.63% (7.36–7.92) |
| Term recall, mean of 3 | **95.1%** | 94.3% |
| General speech (LibriSpeech, 300 utt.) | 5.04% | 5.00% |
| Dev WER, clip level (selection metric) | 9.01% | **4.71%** |
| Size / RTF (Mac) | 140 MB / 0.02 | 140 MB / 0.02 |

**Result: no improvement on the test set.** WER is 0.39 points higher and the
3-run ranges only touch (7.12–7.36 vs 7.36–7.92), so v1 is not better and
probably slightly worse, despite a 48% drop in dev WER. General speech is
unchanged (no forgetting).

Why (8.04 L6, the largest regression):
- "Schrodinger" never occurs in the 8.04 training captions; the model's
  spelling drifted to "Schrader" (34 vs 2 substitutions over 2 runs).
- Number formatting shifted toward the captions' style ("hundred" → "point",
  "and" → "zero"), scored as errors.
- Some prefixes were lost ("nonlinear" → "linear", "eigenfunction" → "function").
- Fewer, longer segments (1,360 vs 1,850; median 3.0 s vs 2.2 s), so the
  model's timestamp behavior changed too.
- Hypothesis rejected: caption style removing fillers ("um") — neither the
  references nor either model contain any.

**Design flaw:** the dev lecture (biology) is not a subject in the test set, so
dev WER could not show the physics regression. v2 needs a dev set drawn from
the test courses.

### Pipeline findings along the way

| Finding | Effect |
|---|---|
| Converting stock base.en with our pinned whisperkittools differs from Argmax's published base.en (fallback off: 7.63% vs 9.03%; on: 7.24% vs ~6.8%) | Fine-tuned models are compared only with our own converted stock model |
| torch 2.5 (required by the converter) crashes in conv1d backward on Apple GPUs | Encoder conv front end frozen (<1% of weights) |
| Batch 8 needs 21.3 GB GPU memory; varying label lengths grew the allocator cache to OOM | Batch 4 × 4 accumulation; labels padded to multiples of 64; memory flat at 10–11 GB |
| Greedy decoding loops on some clips (70 → 509 words), dev WER 17.9% | Dev decoding with temperature fallback and a fixed seed: 9.0%, repeatable |
| Default Whisper fine-tuning targets have no timestamps | Targets built from caption cue times, since the app decodes with timestamps |

## Summarization (Qwen3-1.7B 4-bit, MLX)

Map-reduce over the base.en transcripts of the test lectures, run with
`Tools/summarize` (see README). Greedy decoding, so results are repeatable for a
given transcript.

| Lecture | Length | Words | Model calls | Time (Mac) | Key points span |
|---|---|---:|---:|---:|---|
| 18.06 L22 | 51:50 | 5,720 | 6 | 18.5 s | 0:09 – 44:12 |
| 5.111 L6 | 48:31 | 8,515 | 9 | 23.3 s | 0:00 – 47:46 |
| 8.04 L6 | 1:22:18 | 13,595 | 13 | 39.4 s | 0:02 – 1:19:42 |

Model ~940 MB on disk; peak process memory 1,076 MB. Target "60-minute lecture
in < 60 s" is met on the Mac; iPhone not yet measured.

### What changed during development (measured on these lectures)

| Version | Problem found | Fix |
|---|---|---|
| v1: model picks key points in the reduce step | All points came from the first 21:30 of 51:50 and 13:40 of 48:31; duplicates; LaTeX; "S⁻¹AS = I" (should be Λ) | Key points selected by code, evenly across chunks; reduce writes only the overview; LaTeX converted to plain text |
| v2 | Points copied transcript lines; near-duplicate points | Map prompt asks for distinct ideas in own words |
| v3 | Model copied the prompt's example sentence into its output | Content-free format example, filtered from output; run-on points split |

### Known limitations (v4, recorded above)

- **Factual errors remain**, e.g. "the square root of 5 is approximately 1.618"
  (the lecture says (1+√5)/2 ≈ 1.618). Factual consistency is not yet measured.
- Some key points are still near-quotes of the transcript.
- Prompts were adjusted while reading test-lecture outputs (only for obvious
  formatting failures). Further prompt tuning must use the dev split (7.016 L4)
  so test results stay unbiased.

Next: an evaluation set (factual consistency, key-concept coverage) and a
comparison with larger models (Qwen3-4B, Qwen3.5-2B) on the dev split.

## Keyword search (SQLite FTS5)

`Tools/searchbench` builds a database by repeating the 3 test transcripts
(real Whisper output) and times queries (limit 50, 20 runs after a warm-up).
Repeating text gives more matches per query than a real library, so this is
a slightly harsher test.

100 hours (99 lectures, 117,315 segments), Mac15,6:

| Query | Results | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|
| eigenvalue | 50 | 3.8 | 4.6 |
| determinant | 50 | 1.8 | 2.1 |
| schrodinger | 50 | 3.4 | 4.8 |
| eigen (prefix) | 50 | 9.6 | 10.7 |
| the (stopword only) | 50 | 4.5 | 4.6 |
| wave function | 50 | 6.4 | 7.2 |
| principal quantum number | 50 | 1.5 | 1.7 |
| xylophone (no match) | 0 | 0.4 | 0.4 |

Worst p95: **10.7 ms** (target < 100 ms). At 200 hours the worst p95 is 33 ms.

### Optimization log (200 hours, query "the")

| Attempt | p95 | Kept? |
|---|---:|---|
| Rank all matches with bm25, highlight in the same query | 165.7 ms | baseline |
| Order by FTS5's hidden `rank` column | 226.7 ms | no |
| Rank in a subquery, highlight only the top 50 | 352.4 ms | no (re-runs MATCH per result) |
| Ignore stopwords; stopword-only queries unranked | **8.7 ms** | yes |

The cost was scoring every match of a word found in nearly every segment.
iPhone search latency not yet measured.

## On-device performance

RTF (real-time factor) = processing time / audio duration. Lower is better; target < 0.3.

| Model | Device | Audio | RTF | Caption latency | Peak memory | Date |
|---|---|---|---:|---:|---:|---|
| Whisper base.en | Mac15,6 (dev Mac), release build | 3 test lectures, 3 h 2 min | 0.020–0.025 | n/a | not measured | 2026-10-10 |

A 50-minute lecture transcribes in about one minute on the Mac. Model load
(after download) takes about 15 s. iPhone numbers still to be measured.
