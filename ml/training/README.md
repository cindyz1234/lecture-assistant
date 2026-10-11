# Fine-tuning Whisper

Fine-tunes a Whisper model on OCW lecture clips on the Mac GPU, converts it to
WhisperKit's Core ML format, and evaluates it with the app's own pipeline.
Results and the run log are in [docs/RESULTS.md](../../docs/RESULTS.md).

## Environment

Training and conversion share one environment pinned to the versions the
WhisperKit converter (whisperkittools) supports. torch 2.5.0 needs Python ≤ 3.12.

```sh
python3.12 -m venv .venv-train
.venv-train/bin/pip install -r ml/training/requirements.txt
```

## Steps

```sh
# 1. Data: download train/dev lectures (videos deleted after extracting audio)
#    and build clip manifests with timestamped captions (no audio is copied)
python3 ml/data/download.py --split train --delete-video
python3 ml/data/download.py --split dev --delete-video
python3 ml/training/make_dataset.py --split train --split dev

# 2. Check the training captions aren't spliced (needs base.en transcripts of them)
Tools/.build/release/transcribe --out ml/eval/outputs/base.en-traindev ml/data/processed/<train and dev lectures>.wav
python3 ml/eval/check_reference.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en-traindev

# 3. Smoke test, then train (best epoch by dev WER -> checkpoints/<run>/best)
.venv-train/bin/python ml/training/train_whisper.py --run smoke --max-train 16 --max-dev 8 --epochs 2
.venv-train/bin/python ml/training/train_whisper.py --run base-en-v2b --lr 5e-6 --epochs 3 --dev-stride 3 --freeze-encoder

# 4. Convert to Core ML (also convert the stock model the same way, as the baseline)
ml/training/export_coreml.sh openai/whisper-base.en ml/training/coreml/stock
ml/training/export_coreml.sh ml/training/checkpoints/base-en-v2b/best ml/training/coreml/base-en-v2b

# 5. Evaluate with the app pipeline: 3 runs each (fallback randomness), plus general speech
Tools/.build/release/transcribe --model-folder ml/training/coreml/base-en-v1/model \
    --out ml/eval/outputs/finetuned-v1-run1 ml/data/processed/{18.06-L22,5.111-L06,8.04-L06}.wav
python3 ml/eval/wer.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/finetuned-v1-run1 --manifest ml/data/manifest.csv --split test
python3 ml/eval/term_recall.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/finetuned-v1-run1 --manifest ml/data/manifest.csv --split test
python3 ml/data/download_librispeech.py --count 300
```

## Things that matter

- **Targets have timestamps.** The app decodes with timestamps and its windowing
  depends on them, so targets are `<|t|> text <|t|>` per caption cue.
- **Compare against the stock model converted the same way.** The converter
  alone changes WER.
- **Use 3 runs.** WhisperKit's temperature fallback makes runs differ by ~0.2 points.
- **The test split is never trained on or tuned against.** The dev set comes
  from the same courses as the test set (v1's didn't; see RESULTS.md).
- **Choose between configurations on dev only** (`train_whisper.py --eval-only
  --model <checkpoint>` scores the full dev set); run only the chosen model on test.
- `--dev-stride 3` evaluates every 3rd dev clip during training to save time.
- Mac GPU (MPS) specifics: the encoder conv layers are frozen (a torch 2.5
  backward-pass bug), batch 4 × 4 accumulation, labels padded to multiples of 64.
