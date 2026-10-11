#!/bin/sh
# Convert a Hugging Face Whisper checkpoint to WhisperKit's Core ML format.
#
#   ml/training/export_coreml.sh <checkpoint dir or HF model id> <output dir>
#   ml/training/export_coreml.sh ml/training/checkpoints/base-en-v1/best ml/training/coreml/base-en-v1
#
# Writes <output dir>/model with MelSpectrogram, AudioEncoder and TextDecoder
# (.mlmodelc) plus config.json / generation_config.json, which WhisperKit reads
# and whisperkittools doesn't copy. Load it with `transcribe --model-folder`.
set -eu
source_model="$1"
output="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
python="$root/.venv-train/bin/python"

"$root/.venv-train/bin/whisperkit-generate-model" --model-version "$source_model" --output-dir "$output/work"
# The converter names its folder after --model-version (e.g. a local path), so
# find it by its contents rather than its name.
converted="$(dirname "$(find "$output/work" -maxdepth 2 -type d -name 'AudioEncoder.mlmodelc' | head -1)")"
[ -d "$converted/AudioEncoder.mlmodelc" ] || { echo "conversion output not found in $output/work" >&2; exit 1; }
rm -rf "$output/model"
mkdir -p "$output/model"
cp -R "$converted"/*.mlmodelc "$output/model/"

# Copy the configs from the source model (local folder or Hugging Face).
"$python" - "$source_model" "$output/model" <<'PY'
import os, shutil, sys
from huggingface_hub import hf_hub_download
source, destination = sys.argv[1], sys.argv[2]
for name in ("config.json", "generation_config.json"):
    path = os.path.join(source, name) if os.path.isdir(source) else hf_hub_download(source, name)
    shutil.copy(path, os.path.join(destination, name))
PY
rm -rf "$output/work"
echo "Exported $source_model -> $output/model"
ls "$output/model"
