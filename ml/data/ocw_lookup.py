"""Look up MIT OpenCourseWare lectures and print manifest.csv rows.

For each lecture page this script checks the page's license, then extracts the
direct video download (archive.org) and the caption file (.vtt) used as the
reference transcript. Lectures that are not CC BY-NC-SA, or that lack a direct
download or captions, are reported and skipped.

Examples:
    # List lecture pages in a course's video gallery
    python3 ml/data/ocw_lookup.py --gallery \\
        https://ocw.mit.edu/courses/18-06-linear-algebra-spring-2010/video_galleries/video-lectures/

    # Print manifest rows for specific lectures
    python3 ml/data/ocw_lookup.py --course "18.06 Linear Algebra (Spring 2010)" --id-prefix 18.06 \\
        --split train URL [URL ...]
"""

from __future__ import annotations

import argparse
import csv
import html
import re
import sys
from urllib.parse import urljoin, urlparse

from netutil import urlopen

OCW_HOST = "ocw.mit.edu"

_TITLE = re.compile(r"<title>(.*?)</title>", re.S | re.I)
_VIDEO = re.compile(r"https?://(?:www\.)?archive\.org/download/[^\"'\s<>]+\.mp4")
_CAPTIONS = re.compile(r"""(?:href|src)="([^"]+\.vtt)\"""")
_LICENSE = re.compile(r"creativecommons\.org/licenses/by-nc-sa/", re.I)
_RESERVED = re.compile(r"all rights reserved", re.I)
_LECTURE_NUMBER = re.compile(r"lecture[-\s]*(\d+)", re.I)


def fetch(url: str) -> str:
    with urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8", errors="replace")


def require_ocw(url: str) -> None:
    if urlparse(url).hostname != OCW_HOST:
        raise SystemExit(f"Not an OCW URL: {url}")


def list_gallery(gallery_url: str) -> list[str]:
    """Return lecture resource page URLs linked from a course video gallery."""
    require_ocw(gallery_url)
    course_path = "/".join(urlparse(gallery_url).path.split("/")[:3])  # /courses/<slug>
    page = fetch(gallery_url)
    paths = re.findall(rf'href="({re.escape(course_path)}/resources/[^"#?]+)"', page)
    return list(dict.fromkeys(urljoin(gallery_url, p) for p in paths))  # dedupe, keep order


def lookup(lecture_url: str) -> dict[str, str]:
    """Return lecture details, or raise ValueError explaining why it can't be used."""
    require_ocw(lecture_url)
    page = fetch(lecture_url)

    if _RESERVED.search(page):
        raise ValueError('marked "All rights reserved"')
    if not _LICENSE.search(page):
        raise ValueError("no CC BY-NC-SA license found on page")

    videos = sorted(set(_VIDEO.findall(page)))
    if len(videos) != 1:
        raise ValueError(f"expected 1 direct video download, found {len(videos)}")
    captions = sorted(set(_CAPTIONS.findall(page)))
    if len(captions) != 1:
        raise ValueError(f"expected 1 caption file, found {len(captions)}")

    title_match = _TITLE.search(page)
    title = html.unescape(title_match.group(1)).split("|")[0].strip() if title_match else ""
    return {
        "lecture_title": title,
        "source_page": lecture_url,
        "video_url": "https://" + videos[0].split("://", 1)[1].removeprefix("www."),
        "transcript_url": urljoin(lecture_url, captions[0]),
        "license": "CC BY-NC-SA 4.0",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gallery", help="print lecture page URLs from this video gallery and exit")
    parser.add_argument("--course", help='e.g. "18.06 Linear Algebra (Spring 2010)"')
    parser.add_argument("--id-prefix", help="lecture_id prefix, e.g. 18.06")
    parser.add_argument("--split", choices=["train", "dev", "test"], default="train")
    parser.add_argument("urls", nargs="*", help="OCW lecture resource page URLs")
    args = parser.parse_args()

    if args.gallery:
        for url in list_gallery(args.gallery):
            print(url)
        return 0
    if not (args.course and args.id_prefix and args.urls):
        parser.error("--course, --id-prefix and at least one URL are required")

    writer = csv.writer(sys.stdout, lineterminator="\n")
    failed = False
    for url in args.urls:
        try:
            row = lookup(url)
        except (ValueError, OSError) as error:
            print(f"SKIP {url}: {error}", file=sys.stderr)
            failed = True
            continue
        number = _LECTURE_NUMBER.search(row["lecture_title"]) or _LECTURE_NUMBER.search(url)
        suffix = f"L{int(number.group(1)):02d}" if number else urlparse(url).path.rstrip("/").split("/")[-1]
        writer.writerow([
            f"{args.id_prefix}-{suffix}", args.course, row["lecture_title"], row["source_page"],
            row["video_url"], row["transcript_url"], row["license"], args.split,
        ])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
