from check_reference import displaced_fraction

SPOKEN = (
    "today we talk about eigenvalues and eigenvectors of a matrix and how to find them "
    "first we subtract lambda times the identity and take the determinant of the result "
    "then we solve for lambda and plug each one back in to find the eigenvectors"
)
MIDDLE = "first we subtract lambda times the identity and take the determinant of the result"


def test_clean_reference_has_no_displaced_words() -> None:
    assert displaced_fraction(SPOKEN, SPOKEN) == 0.0


def test_recognition_errors_are_not_displacement() -> None:
    hypothesis = SPOKEN.replace("eigenvalues", "egg and values").replace("determinant", "determine it")
    assert displaced_fraction(SPOKEN, hypothesis) == 0.0


def test_detects_passage_moved_to_another_position() -> None:
    # The reference has the middle passage at the end; the audio has it in the middle.
    spliced_reference = SPOKEN.replace(MIDDLE + " ", "") + " " + MIDDLE
    fraction = displaced_fraction(spliced_reference, SPOKEN)
    assert fraction >= len(MIDDLE.split()) / len(spliced_reference.split()) * 0.9
