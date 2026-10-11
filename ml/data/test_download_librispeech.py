from download_librispeech import every_nth


def test_every_nth_is_deterministic_and_spread_out() -> None:
    ids = [f"u{i:03d}" for i in range(100)]

    chosen = every_nth(list(reversed(ids)), 4)

    assert chosen == ["u000", "u025", "u050", "u075"]
    assert every_nth(ids, 500) == ids
