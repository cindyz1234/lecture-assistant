import pytest

import ocw_lookup

LECTURE_URL = "https://ocw.mit.edu/courses/18-06-linear-algebra-spring-2010/resources/lecture-21-eigenvalues/"
LICENSE_LINK = '<a href="https://creativecommons.org/licenses/by-nc-sa/4.0/">Creative Commons License</a>'
VIDEO_LINK = '<a href="http://www.archive.org/download/MIT18.06S05_MP4/21.mp4">Download video</a>'
CAPTIONS = '<track src="/courses/18-06-linear-algebra-spring-2010/abc_cdZnhQjJu4I.vtt">'


def page(*parts: str) -> str:
    return "<html><title>Lecture 21: Eigenvalues | 18.06 | MIT OpenCourseWare</title>" + "".join(parts) + "</html>"


@pytest.fixture
def serve(monkeypatch):
    def _serve(html: str) -> None:
        monkeypatch.setattr(ocw_lookup, "fetch", lambda url: html)
    return _serve


def test_extracts_links_from_licensed_page(serve) -> None:
    serve(page(LICENSE_LINK, VIDEO_LINK, CAPTIONS))

    row = ocw_lookup.lookup(LECTURE_URL)

    assert row["lecture_title"] == "Lecture 21: Eigenvalues"
    assert row["video_url"] == "https://archive.org/download/MIT18.06S05_MP4/21.mp4"
    assert row["transcript_url"] == "https://ocw.mit.edu/courses/18-06-linear-algebra-spring-2010/abc_cdZnhQjJu4I.vtt"
    assert row["license"] == "CC BY-NC-SA 4.0"


def test_rejects_all_rights_reserved(serve) -> None:
    serve(page(LICENSE_LINK, VIDEO_LINK, CAPTIONS, "<p>© 2010 Lecturer. All rights reserved.</p>"))

    with pytest.raises(ValueError, match="All rights reserved"):
        ocw_lookup.lookup(LECTURE_URL)


def test_rejects_page_without_cc_license(serve) -> None:
    serve(page(VIDEO_LINK, CAPTIONS))

    with pytest.raises(ValueError, match="license"):
        ocw_lookup.lookup(LECTURE_URL)


def test_rejects_page_without_direct_download(serve) -> None:
    # e.g. a lecture only available as a YouTube embed
    serve(page(LICENSE_LINK, '<iframe src="https://www.youtube.com/embed/cdZnhQjJu4I"></iframe>', CAPTIONS))

    with pytest.raises(ValueError, match="direct video download"):
        ocw_lookup.lookup(LECTURE_URL)


def test_rejects_non_ocw_urls() -> None:
    with pytest.raises(SystemExit):
        ocw_lookup.lookup("https://www.youtube.com/watch?v=cdZnhQjJu4I")
