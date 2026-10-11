import Shared
import Testing
@testable import Summarization

struct SummaryFormatTests {
    @Test(arguments: [
        ("[1:02] Defines eigenvalues", 62_000, "Defines eigenvalues"),
        ("- [1:02] Bulleted point", 62_000, "Bulleted point"),
        ("* [0:05] Star bullet", 5_000, "Star bullet"),
        ("2. [0:05] Numbered point", 5_000, "Numbered point"),
        ("[0:05] - Dash after timestamp", 5_000, "Dash after timestamp"),
        ("[1:02:03] With hours", 3_723_000, "With hours"),
        ("[75:10] Minutes past an hour", 4_510_000, "Minutes past an hour"),
    ])
    func parsesTimestampedPoint(line: String, milliseconds: Int64, text: String) {
        let points = SummaryFormat.parsePoints(line)
        #expect(points == [SummaryItem(text: text, start: LectureTime(milliseconds: milliseconds))])
    }

    @Test func ignoresLinesWithoutValidTimestamps() {
        let output = """
        Here are the key points:
        [1:75] Invalid seconds
        [0:10]
        Plain sentence
        [0:20] Valid one
        """
        #expect(SummaryFormat.parsePoints(output).map(\.text) == ["Valid one"])
    }

    @Test func keepsOnlyFirstOfTwoPointsRunTogether() {
        let points = SummaryFormat.parsePoints("[1:20] Binding energy is negative. [1:28] We are in the n = 5 state.")
        #expect(points == [SummaryItem(text: "Binding energy is negative.", start: ms(80_000))])
    }

    @Test func stripsReasoningBlocks() {
        #expect(SummaryFormat.stripReasoning("<think>\nhmm\n</think>\n[0:01] Point") == "\n[0:01] Point")
        #expect(SummaryFormat.stripReasoning("[0:01] Point\n<think>cut off") == "[0:01] Point\n")
        #expect(SummaryFormat.parsePoints("<think>[0:09] not a point</think>[0:01] Point").map(\.text) == ["Point"])
    }

    @Test func parsesOverviewBeforeFirstPoint() {
        let output = """
        <think></think>
        Overview: This lecture introduces eigenvalues.
        It ends with diagonalization.
        Key points:
        [0:10] First point
        Trailing text is not part of the overview
        """
        #expect(SummaryFormat.parseLeadingText(output) == "This lecture introduces eigenvalues. It ends with diagonalization.")
    }

    @Test(arguments: [
        ("$ Ax = \\lambda x $", "Ax = λ x"),
        ("$ S^{-1} A S = \\Lambda $", "S^-1 A S = Λ"),
        ("energy \\mathbf{E}_{n} is \\hbar \\omega", "energy E_n is ħ ω"),
        ("\\int_0^\\infty f \\to 0", "∫_0^∞ f → 0"),  // \int must not match inside \infty
        ("No math here.", "No math here."),
    ])
    func convertsLatexToPlainText(latex: String, plain: String) {
        #expect(SummaryFormat.plainText(latex) == plain)
    }

    @Test func dropsDanglingLeadInFromOverview() {
        #expect(SummaryFormat.parseLeadingText("It covers eigenvalues. The key ideas are:") == "It covers eigenvalues.")
        #expect(SummaryFormat.parseLeadingText("Key ideas:") == "")
    }

    @Test func formatsTranscriptLinesWithTimestamps() {
        let lines = SummaryFormat.transcriptLines([segment(0, 4_000, "Hello."), segment(65_000, 70_000, "Next.")])
        #expect(lines == "[0:00] Hello.\n[1:05] Next.")
    }

    @Test func snapsToContainingSegmentStart() {
        let segments = [segment(0, 10_000), segment(10_000, 20_000), segment(30_000, 40_000)]
        #expect(SummaryFormat.snap(ms(15_000), to: segments) == ms(10_000))
        #expect(SummaryFormat.snap(ms(10_000), to: segments) == ms(10_000))
    }

    @Test func snapsInventedTimestampToNearestSegment() {
        let segments = [segment(0, 10_000), segment(30_000, 40_000)]
        #expect(SummaryFormat.snap(ms(24_000), to: segments) == ms(30_000))  // in a gap
        #expect(SummaryFormat.snap(ms(5_940_000), to: segments) == ms(30_000))  // e.g. "[99:00]"
    }
}

func ms(_ milliseconds: Int64) -> LectureTime {
    LectureTime(milliseconds: milliseconds)
}

func segment(_ start: Int64, _ end: Int64, _ text: String = "words") -> TranscriptSegment {
    TranscriptSegment(text: text, start: ms(start), end: ms(end), isFinal: true)
}
