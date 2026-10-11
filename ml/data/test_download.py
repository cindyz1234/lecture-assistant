from pathlib import Path

import download

ROW = {
    "lecture_id": "18.06-L22",
    "video_url": "https://archive.org/download/x/22.mp4",
    "transcript_url": "https://ocw.mit.edu/x.vtt",
}


def fake_network(monkeypatch, tmp_path: Path) -> list[str]:
    """Redirects the data folders to tmp_path and records 'downloads' instead of fetching."""
    fetched: list[str] = []
    monkeypatch.setattr(download, "RAW_DIR", tmp_path / "raw")
    monkeypatch.setattr(download, "PROCESSED_DIR", tmp_path / "processed")
    (tmp_path / "raw").mkdir()
    (tmp_path / "processed").mkdir()

    def fake_download(url: str, destination: Path) -> None:
        fetched.append(url)
        destination.write_text("data")

    monkeypatch.setattr(download, "download", fake_download)
    monkeypatch.setattr(download, "extract_audio", lambda video, wav: wav.write_text("audio"))
    return fetched


def test_skips_video_when_audio_already_extracted(monkeypatch, tmp_path: Path) -> None:
    fetched = fake_network(monkeypatch, tmp_path)
    (tmp_path / "processed" / "18.06-L22.wav").write_text("audio")

    download.fetch_lecture(ROW, delete_video=False)

    assert fetched == [ROW["transcript_url"]]


def test_delete_video_keeps_audio_and_captions(monkeypatch, tmp_path: Path) -> None:
    fetched = fake_network(monkeypatch, tmp_path)

    download.fetch_lecture(ROW, delete_video=True)

    assert fetched == [ROW["transcript_url"], ROW["video_url"]]
    assert not (tmp_path / "raw" / "18.06-L22.mp4").exists()
    assert (tmp_path / "raw" / "18.06-L22.vtt").exists()
    assert (tmp_path / "processed" / "18.06-L22.wav").exists()
