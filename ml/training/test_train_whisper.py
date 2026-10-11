from train_whisper import build_labels


class FakeTokenizer:
    """Whisper-like ids: <|endoftext|> = 50256, <|0.00|> = 50363, one id per word."""

    special = {"<|endoftext|>": 50256, "<|0.00|>": 50363}

    def convert_tokens_to_ids(self, token: str) -> int:
        return self.special[token]

    def encode(self, text: str, add_special_tokens: bool = True) -> list[int]:
        assert not add_special_tokens
        assert text.startswith(" "), "Whisper text tokens start with a space"
        return [len(word) for word in text.split()]


def test_labels_wrap_each_cue_in_timestamps_and_end_with_eot() -> None:
    labels = build_labels([[0.2, 2.1, "So the"], [2.1, 5.9, "determinant."]], FakeTokenizer())

    assert labels == [
        50363 + 10, 2, 3, 50363 + 105,   # <|0.20|> So the <|2.10|>
        50363 + 105, 12, 50363 + 295,    # <|2.10|> determinant. <|5.90|>
        50256,                           # <|endoftext|>
    ]


def test_timestamps_are_clamped_to_the_30_second_window() -> None:
    labels = build_labels([[-1.0, 31.0, "x"]], FakeTokenizer())

    assert labels[0] == 50363            # <|0.00|>
    assert labels[-2] == 50363 + 1500    # <|30.00|>
