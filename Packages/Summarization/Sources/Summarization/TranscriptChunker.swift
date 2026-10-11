import Shared

/// A contiguous run of transcript segments small enough for one model call.
struct TranscriptChunk: Sendable, Equatable {
    var segments: [TranscriptSegment]

    var start: LectureTime { segments.first?.start ?? .zero }
    var end: LectureTime { segments.last?.end ?? .zero }
}

enum TranscriptChunker {
    /// Splits segments into chunks of at most `maxWords` words, never splitting a
    /// segment. A single segment longer than `maxWords` becomes its own chunk.
    static func chunks(_ segments: [TranscriptSegment], maxWords: Int) -> [TranscriptChunk] {
        precondition(maxWords > 0, "maxWords must be positive")
        var chunks: [TranscriptChunk] = []
        var current: [TranscriptSegment] = []
        var currentWords = 0

        for segment in segments where !segment.text.allSatisfy(\.isWhitespace) {
            let words = segment.text.split(whereSeparator: \.isWhitespace).count
            if !current.isEmpty, currentWords + words > maxWords {
                chunks.append(TranscriptChunk(segments: current))
                current = []
                currentWords = 0
            }
            current.append(segment)
            currentWords += words
        }
        if !current.isEmpty {
            chunks.append(TranscriptChunk(segments: current))
        }
        return chunks
    }
}
