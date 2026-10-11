from pathlib import Path

from term_recall import count_terms, load_terms, term_recall
from wer import normalize


def test_counts_whole_words_and_plurals() -> None:
    text = normalize("Eigenvalues and an eigenvalue; eigenvectors. Hamiltonians! not eigenvaluex")
    counts = count_terms(text, ["eigenvalue", "eigenvector", "hamiltonian"])

    assert counts == {"eigenvalue": 2, "eigenvector": 1, "hamiltonian": 1}


def test_counts_phrases() -> None:
    counts = count_terms(normalize("The principal quantum number, then a quantum number."), [
        "quantum number", "principal quantum number",
    ])

    assert counts == {"quantum number": 2, "principal quantum number": 1}


def test_recall_caps_matches_at_reference_count() -> None:
    reference = normalize("Bohr radius. The Bohr model. Radial part.")
    hypothesis = normalize("bore radius. The Bohr model. Bohr again. Radio part.")

    matched, total, missed = term_recall(reference, hypothesis, ["bohr", "radial"])

    assert (matched, total) == (2, 3)  # Bohr: min(2, 2) = 2; radial: min(1, 0) = 0
    assert missed == {"radial": 1}


def test_load_terms_skips_comments_and_normalizes(tmp_path: Path) -> None:
    terms_file = tmp_path / "terms.txt"
    terms_file.write_text("# header\nSchrodinger\n\nWave-function  # comment\nschrodinger\n")

    assert load_terms(terms_file) == ["schrodinger", "wave function"]
