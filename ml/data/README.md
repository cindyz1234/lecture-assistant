# Lecture data

Media files are **never committed**. `manifest.csv` records where each lecture
comes from; `download.py` fetches the files into gitignored folders.

## Manifest columns

| Column | Meaning |
|---|---|
| `lecture_id` | Short unique ID used for filenames, e.g. `18.06-L01` |
| `course` | Course number and title, e.g. `18.06 Linear Algebra (Spring 2010)` |
| `lecture_title` | Lecture title as listed on OCW |
| `source_page` | OCW page the lecture is listed on (for attribution) |
| `video_url` | Direct MP4 download link from the OCW page (**not YouTube**) |
| `transcript_url` | Direct link to the OCW transcript (`.srt`, `.vtt`, `.txt` or `.pdf`); may be empty |
| `license` | Must be `CC BY-NC-SA` (any version). Skip items marked "All rights reserved". |
| `split` | `train`, `dev` or `test`. Decide `test` before looking at any results and never train on it. |

## Usage

```sh
python3 ml/data/download.py              # all rows
python3 ml/data/download.py --split test # only the test split
```

Outputs:
- `ml/data/raw/<lecture_id>.<ext>`: original video and transcript
- `ml/data/processed/<lecture_id>.wav`: 16 kHz mono 16-bit WAV

Requires `ffmpeg` on `PATH`.
