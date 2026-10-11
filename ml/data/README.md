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

## Adding lectures

`ocw_lookup.py` checks a lecture page's license and prints a manifest row with
its direct video download and caption file:

```sh
# 1. List the lecture pages in a course's video gallery
python3 ml/data/ocw_lookup.py --gallery https://ocw.mit.edu/courses/<course>/video_galleries/<gallery>/

# 2. Print manifest rows for chosen lectures, then append them to manifest.csv
python3 ml/data/ocw_lookup.py --course "18.06 Linear Algebra (Spring 2010)" --id-prefix 18.06 \
    --split train <lecture page URL> ...
```

Lectures that aren't CC BY-NC-SA, are marked "All rights reserved", or lack a
direct download or captions are skipped with a reason.

## Current selection

Chosen before any measurement. Lecture 1s (mostly logistics) are skipped.

| Course | train | dev | test |
|---|---|---|---|
| 18.06 Linear Algebra (Spring 2010) | L2, L3, L5 | L4 | L22 |
| 8.04 Quantum Physics I (Spring 2013) | L2, L3, L5 | L4 | L6 |
| 5.111 Principles of Chemical Science (Fall 2008) | L2, L3, L5 | L4 | L6 |
| 7.016 Introductory Biology (Fall 2018) | L2, L3, L4 | | |

v2 (2026-10-11) added lectures 4 and 5 of the three test courses and moved
dev to lecture 4 of each test course (it was 7.016 L4), so the dev set has the
same subjects as the test set.

The reference transcripts are OCW's caption files (`.vtt`).

### Excluded lectures

| Lecture | Reason | Replaced by |
|---|---|---|
| 18.06 L21 | OCW's captions **and** PDF transcript splice text from later in the lecture into earlier cues (e.g. at 11:53, "can you tell me one vector that which is lambda x, and I have a three x…"). 2.0% of reference words were displaced; its WER was 19.5% vs. 4–9% for the other test lectures. | 18.06 L22, the next lecture, which passed the same check (0.0%). |

Rule: every test lecture must pass `ml/eval/check_reference.py` (≤ 1% displaced
reference words). If one fails, it is replaced by the next lecture of the same
course that passes. The rule depends on the reference's word order, not on
model accuracy.

## Usage

```sh
python3 ml/data/download.py                              # all rows
python3 ml/data/download.py --split test                 # only the test split
python3 ml/data/download.py --split train --delete-video # keep only audio + captions
```

Outputs:
- `ml/data/raw/<lecture_id>.<ext>`: original video and transcript
- `ml/data/processed/<lecture_id>.wav`: 16 kHz mono 16-bit WAV

Requires `ffmpeg` on `PATH`.
