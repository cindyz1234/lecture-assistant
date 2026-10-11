"""Fine-tune a Whisper model on lecture clips from make_dataset.py.

Targets use Whisper's timestamped format (<|t|> text <|t|> per caption cue),
because the app decodes with timestamps and relies on them for windowing.
Dev WER is measured before training and after every epoch; the best epoch is
saved. Every run writes config.json and metrics.jsonl for the run log.

    # Smoke test on a tiny subset (minutes):
    .venv-train/bin/python ml/training/train_whisper.py --run smoke --max-train 32 --max-dev 8 --epochs 1
    # Full run:
    .venv-train/bin/python ml/training/train_whisper.py --run base-en-v1
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import random
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Any, Protocol

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml/eval"))

from wer import normalize  # noqa: E402  (shared normalization keeps dev WER comparable)

TIMESTAMP_STEP = 0.02
MAX_TIMESTAMP = 30.0


class TokenizerLike(Protocol):
    def encode(self, text: str, add_special_tokens: bool = ...) -> list[int]: ...
    def convert_tokens_to_ids(self, token: str) -> int: ...


def build_labels(cues: list[list[Any]], tokenizer: TokenizerLike) -> list[int]:
    """Decoder targets in Whisper's timestamped format, without the start token.

    `[[0.2, 2.1, "So the"], [2.1, 5.9, "determinant."]]` becomes
    `<|0.20|> So the<|2.10|><|2.10|> determinant.<|5.90|><|endoftext|>`. The model
    prepends <|startoftranscript|> itself (its decoder start token).
    """
    timestamp_begin = tokenizer.convert_tokens_to_ids("<|0.00|>")
    end_of_text = tokenizer.convert_tokens_to_ids("<|endoftext|>")

    def timestamp(seconds: float) -> int:
        seconds = min(max(seconds, 0.0), MAX_TIMESTAMP)
        return timestamp_begin + round(seconds / TIMESTAMP_STEP)

    labels: list[int] = []
    for start, end, text in cues:
        labels.append(timestamp(start))
        labels.extend(tokenizer.encode(" " + text.strip(), add_special_tokens=False))
        labels.append(timestamp(end))
    labels.append(end_of_text)
    return labels


def read_wav(path: Path) -> list[float] | Any:
    """16-bit mono WAV -> float32 numpy array in [-1, 1]."""
    import numpy as np

    with wave.open(str(path), "rb") as source:
        frames = source.readframes(source.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def load_examples(path: Path, limit: int | None) -> list[dict[str, Any]]:
    examples = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return examples[:limit] if limit else examples


def git_commit() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", required=True, help="run name; outputs go to ml/training/checkpoints/<run>")
    parser.add_argument("--model", default="openai/whisper-base.en")
    parser.add_argument("--train", type=Path, default=ROOT / "ml/data/clips/train.jsonl")
    parser.add_argument("--dev", type=Path, default=ROOT / "ml/data/clips/dev.jsonl")
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--lr", type=float, default=1e-5)
    # Batch 8 needs 21.3 GB of GPU memory (OOM at the Mac's 22.6 GB limit); batch 4 needs 12.6 GB.
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--grad-accum", type=int, default=4, help="effective batch = batch-size * grad-accum")
    parser.add_argument("--warmup", type=float, default=0.1, help="fraction of steps with linear LR warm-up")
    parser.add_argument("--freeze-encoder", action="store_true", help="train only the decoder")
    parser.add_argument("--max-train", type=int, help="use only the first N training clips (smoke tests)")
    parser.add_argument("--max-dev", type=int, help="use only the first N dev clips")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    import jiwer
    import torch
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    run_dir = ROOT / "ml/training/checkpoints" / args.run
    run_dir.mkdir(parents=True, exist_ok=True)

    processor = WhisperProcessor.from_pretrained(args.model)
    model = WhisperForConditionalGeneration.from_pretrained(args.model).to(device)
    # Freeze the encoder's convolutional front end (conv1/conv2, <1% of weights).
    # torch 2.5 (pinned by the Core ML converter) crashes in conv1d's backward
    # pass on Apple GPUs ("view size is not compatible with input tensor's size
    # and stride"); with these frozen it is never run. These layers are low-level
    # acoustic filters, which vocabulary adaptation doesn't need to change.
    model.model.encoder.conv1.requires_grad_(False)
    model.model.encoder.conv2.requires_grad_(False)
    if args.freeze_encoder:
        model.model.encoder.requires_grad_(False)
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())

    train = load_examples(args.train, args.max_train)
    dev = load_examples(args.dev, args.max_dev)
    print(f"device={device} train={len(train)} clips dev={len(dev)} clips "
          f"trainable={trainable / 1e6:.1f}M of {total / 1e6:.1f}M parameters", flush=True)

    def features(batch: list[dict[str, Any]]) -> torch.Tensor:
        audio = [read_wav(ROOT / example["audio"]) for example in batch]
        return processor.feature_extractor(audio, sampling_rate=16_000, return_tensors="pt").input_features.to(device)

    def labels(batch: list[dict[str, Any]]) -> torch.Tensor:
        sequences = [build_labels(example["cues"], processor.tokenizer) for example in batch]
        # Round the width up to a multiple of 64. With a new tensor shape for every
        # batch, the Apple GPU allocator kept caching buffers it never reused
        # (13 GB of "other allocations") until training ran out of memory.
        width = math.ceil(max(len(s) for s in sequences) / 64) * 64
        padded = [s + [-100] * (width - len(s)) for s in sequences]  # -100 = ignored by the loss
        return torch.tensor(padded, device=device)

    @torch.no_grad()
    def dev_wer() -> float:
        """Dev WER with temperature fallback, like the app (WhisperKit) decodes.

        Plain greedy decoding falls into repetition loops on some clips (one dev
        clip: 70 reference words, 509 output words), which dominated the score.
        Fallback retries such clips at higher temperature; a fixed seed makes
        those retries, and so the metric, repeatable.
        """
        model.eval()
        torch.manual_seed(1234)
        references, hypotheses = [], []
        for i in range(0, len(dev), args.batch_size):
            batch = dev[i:i + args.batch_size]
            generated = model.generate(
                features(batch),
                return_timestamps=True,
                max_new_tokens=300,  # 30 s of speech is ~150 words (~250 tokens with timestamps)
                temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
                compression_ratio_threshold=1.35,  # Hugging Face's zlib-based equivalent of OpenAI's 2.4
                logprob_threshold=-1.0,
            )
            texts = processor.tokenizer.batch_decode(generated, skip_special_tokens=True)
            references += [normalize(example["text"]) for example in batch]
            hypotheses += [normalize(text) for text in texts]
        model.train()
        if device == "mps":
            torch.mps.empty_cache()  # generation leaves large cached buffers behind
        pairs = [(r, h) for r, h in zip(references, hypotheses) if r]
        return jiwer.wer([r for r, _ in pairs], [h for _, h in pairs])

    steps_per_epoch = math.ceil(len(train) / (args.batch_size * args.grad_accum))
    total_steps = steps_per_epoch * args.epochs
    warmup_steps = max(1, int(total_steps * args.warmup))
    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.01)

    def lr_factor(step: int) -> float:
        """Linear warm-up to the full learning rate, then linear decay to 0."""
        if step < warmup_steps:
            return (step + 1) / warmup_steps
        return max(0.0, (total_steps - step) / max(1, total_steps - warmup_steps))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lr_factor)

    config = vars(args) | {
        "train": str(args.train), "dev": str(args.dev), "git_commit": git_commit(), "device": device,
        "machine": platform.machine(), "torch": torch.__version__, "train_clips": len(train), "dev_clips": len(dev),
        "total_steps": total_steps,
    }
    (run_dir / "config.json").write_text(json.dumps(config, indent=2))
    metrics_file = (run_dir / "metrics.jsonl").open("w")

    def log(**values: Any) -> None:
        metrics_file.write(json.dumps(values) + "\n")
        metrics_file.flush()
        print(json.dumps(values), flush=True)

    started = time.time()
    best_wer = dev_wer()
    log(epoch=0, step=0, dev_wer=round(best_wer, 4), minutes=round((time.time() - started) / 60, 1))
    model.save_pretrained(run_dir / "best")
    processor.save_pretrained(run_dir / "best")

    model.train()
    step = 0
    for epoch in range(1, args.epochs + 1):
        random.shuffle(train)
        running_loss, micro_batches = 0.0, 0
        for i in range(0, len(train), args.batch_size):
            batch = train[i:i + args.batch_size]
            loss = model(input_features=features(batch), labels=labels(batch)).loss / args.grad_accum
            loss.backward()
            running_loss += loss.item() * args.grad_accum
            micro_batches += 1
            if micro_batches % args.grad_accum == 0 or i + args.batch_size >= len(train):
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad()
                step += 1
                if device == "mps" and step % 20 == 0:
                    torch.mps.empty_cache()
                if step % 10 == 0:
                    memory = torch.mps.driver_allocated_memory() / 1e9 if device == "mps" else 0.0
                    log(epoch=epoch, step=step, train_loss=round(running_loss / micro_batches, 4),
                        lr=scheduler.get_last_lr()[0], gpu_gb=round(memory, 1))
        wer = dev_wer()
        improved = wer < best_wer
        log(epoch=epoch, step=step, train_loss=round(running_loss / max(1, micro_batches), 4),
            dev_wer=round(wer, 4), best=improved, minutes=round((time.time() - started) / 60, 1))
        if improved:
            best_wer = wer
            model.save_pretrained(run_dir / "best")
            processor.save_pretrained(run_dir / "best")

    log(done=True, best_dev_wer=round(best_wer, 4), minutes=round((time.time() - started) / 60, 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
