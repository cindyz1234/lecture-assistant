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
ml/eval/        evaluation scripts (WER, ...)
Tools/          command-line tools, e.g. `transcribe` for batch evaluation
docs/           DESIGN.md, RESULTS.md
project.yml     XcodeGen spec for the app project
```

## Getting started

Requirements: macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python 3.11+, ffmpeg.

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

## Data and attribution

Evaluation and training audio comes from
[MIT OpenCourseWare](https://ocw.mit.edu), used under the
[Creative Commons BY-NC-SA 4.0 license](https://creativecommons.org/licenses/by-nc-sa/4.0/).
Courses used are listed in [`ml/data/manifest.csv`](ml/data/manifest.csv).
Items marked "All rights reserved" are excluded. Media files are not
redistributed in this repository. This project is non-commercial and is not
affiliated with or endorsed by MIT.
