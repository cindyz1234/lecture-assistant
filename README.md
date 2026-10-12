# Lecture Assistant

A privacy-first iOS + macOS app that transcribes lectures on-device, summarizes
them, and lets you search and ask questions across past lectures, with
timestamp links. Nothing leaves the device.

*Status: early prototype. Imports local lecture files; live recording comes later.*

## Repository layout

```
App/            SwiftUI app (thin UI layer)
Packages/       Swift packages: Shared, AudioCapture, AudioDSP, Transcription,
                Summarization, Storage, Search
ml/data/        manifest.csv + download/extract script (no media committed)
ml/eval/        evaluation scripts (WER, term recall, reference checks)
ml/training/    Whisper fine-tuning and Core ML export (see ml/training/README.md)
Tools/          command-line tools, e.g. `transcribe` for batch evaluation
docs/           DESIGN.md, RESULTS.md
project.yml     XcodeGen spec for the app project
```

## Getting started

Requirements: macOS 15+, Xcode 26+ (with the Metal toolchain), [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python 3.11+, ffmpeg.

```sh
brew install xcodegen ffmpeg

# Signing (one-time): put your team ID in a gitignored local config
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > App/Config/Local.xcconfig

xcodegen generate
open LectureAssistant.xcodeproj
```

Run the package tests:

```sh
for p in Packages/*/; do [ -d "$p/Tests" ] && swift test --package-path "$p"; done
```

ML tooling:

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -r ml/requirements.txt
pytest ml
python3 ml/data/download.py --split test
```

Reproduce the ASR baseline (transcribes with the app's pipeline, then scores
against the OCW captions):

```sh
swift build -c release --package-path Tools
Tools/.build/release/transcribe --model base.en --out ml/eval/outputs/base.en ml/data/processed/*.wav
python3 ml/eval/check_reference.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en
python3 ml/eval/wer.py --ref-dir ml/data/raw --hyp-dir ml/eval/outputs/base.en \
    --manifest ml/data/manifest.csv --split test
```

Summarize the transcripts with the on-device LLM (MLX needs an xcodebuild build
for its Metal shaders; first run downloads Qwen3-1.7B 4-bit, ~940 MB):

```sh
xcodebuild -downloadComponent MetalToolchain   # once, Xcode 26+
xcodebuild build -scheme summarize -destination platform=macOS -configuration Release \
    -derivedDataPath Tools/.xcbuild -skipMacroValidation -skipPackagePluginValidation -workspace Tools
Tools/.xcbuild/Build/Products/Release/summarize --out ml/eval/outputs/summaries \
    ml/eval/outputs/base.en/*.segments.json
```

Benchmark transcript search on 100+ hours built from those transcripts:

```sh
swift run -c release --package-path Tools searchbench --hours 100 ml/eval/outputs/base.en/*.segments.json
```

Evaluate Q&A retrieval (recall@k over the question set, searching all lectures):

```sh
xcodebuild build -scheme qaeval -destination platform=macOS -configuration Release \
    -derivedDataPath Tools/.xcbuild -skipMacroValidation -skipPackagePluginValidation -workspace Tools
Tools/.xcbuild/Build/Products/Release/qaeval --split test --keyword-weight 0.25 \
    --transcripts ml/eval/outputs/base.en --transcripts ml/eval/outputs/base.en-traindev
```

In Xcode, the first build asks you to **Trust & Enable** the MLX package's
macros and build plugin.

### Troubleshooting

- **`unable to spawn process '.../MetalToolchain-…/metal' (No such file or directory)`**
  after a restart: macOS mounts the Metal toolchain at a new path, and SwiftPM's
  cache still points at the old one. Delete the package's `.build` folder (e.g.
  `rm -rf Packages/Summarization/.build`) and build again.
- **Xcode can't find a type that exists** (e.g. `cannot find 'ModelProvider' in
  scope`): new files were added; quit Xcode and run `xcodegen generate`.

## Data and attribution

Evaluation and training audio comes from
[MIT OpenCourseWare](https://ocw.mit.edu), used under the
[Creative Commons BY-NC-SA 4.0 license](https://creativecommons.org/licenses/by-nc-sa/4.0/).
Courses used are listed in [`ml/data/manifest.csv`](ml/data/manifest.csv).
Items marked "All rights reserved" are excluded.

The general-speech check uses a subset of
[LibriSpeech](https://www.openslr.org/12) test-clean (Panayotov et al., 2015),
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Media files are not
redistributed in this repository. This project is non-commercial and is not
affiliated with or endorsed by MIT.
