import Shared
import Testing
@testable import Summarization

struct TranscriptChunkerTests {
    @Test func groupsSegmentsUpToWordBudget() {
        let segments = (0..<6).map { i in
            segment(Int64(i) * 1_000, Int64(i + 1) * 1_000, "one two three")  // 3 words each
        }

        let chunks = TranscriptChunker.chunks(segments, maxWords: 7)

        #expect(chunks.map(\.segments.count) == [2, 2, 2])
        #expect(chunks.map(\.start.milliseconds) == [0, 2_000, 4_000])
        #expect(chunks.map(\.end.milliseconds) == [2_000, 4_000, 6_000])
    }

    @Test func keepsOversizedSegmentWhole() {
        let long = segment(0, 1_000, Array(repeating: "word", count: 50).joined(separator: " "))
        let chunks = TranscriptChunker.chunks([segment(0, 1, "a"), long, segment(2_000, 3_000, "b")], maxWords: 10)

        #expect(chunks.map(\.segments.count) == [1, 1, 1])
    }

    @Test func skipsBlankSegmentsAndHandlesEmptyInput() {
        #expect(TranscriptChunker.chunks([], maxWords: 10).isEmpty)
        #expect(TranscriptChunker.chunks([segment(0, 1, "  ")], maxWords: 10).isEmpty)
    }
}
