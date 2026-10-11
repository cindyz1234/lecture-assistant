import Shared

public enum PassageBuilder {
    /// Groups a lecture's segments into passages of about `length`, starting a
    /// new passage every `stride` so neighbors overlap. Overlap means an idea
    /// that crosses one passage boundary is whole inside another passage.
    /// Passages always start and end on segment boundaries.
    public static func passages(
        _ segments: [TranscriptSegment],
        lectureID: Lecture.ID,
        length: Duration = .seconds(60),
        stride: Duration = .seconds(30)
    ) -> [Passage] {
        let segments = segments
            .filter { !$0.text.allSatisfy(\.isWhitespace) }
            .sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return [] }
        let lengthMs = milliseconds(length)
        let strideMs = milliseconds(stride)

        var passages: [Passage] = []
        var first = 0
        while first < segments.count {
            let startMs = segments[first].start.milliseconds
            var last = first
            while last + 1 < segments.count, segments[last + 1].end.milliseconds - startMs <= lengthMs {
                last += 1
            }
            let slice = segments[first...last]
            passages.append(Passage(
                lectureID: lectureID,
                start: slice.first!.start,
                end: slice.last!.end,
                text: slice.map(\.text).joined(separator: " "),
                segmentIDs: slice.map(\.id)
            ))
            if last == segments.count - 1 { break }
            // Next passage: the first segment starting at least `stride` later,
            // but always make progress.
            let next = segments.indices.first { $0 > first && segments[$0].start.milliseconds >= startMs + strideMs }
            first = min(next ?? last + 1, last + 1)
        }
        return passages
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}

public enum PassageIndexer {
    /// Splits a lecture into passages and embeds them, in batches.
    public static func embed(
        _ segments: [TranscriptSegment],
        lectureID: Lecture.ID,
        embedder: any TextEmbedder,
        batchSize: Int = 32
    ) async throws -> [EmbeddedPassage] {
        let passages = PassageBuilder.passages(segments, lectureID: lectureID)
        var embedded: [EmbeddedPassage] = []
        for batchStart in stride(from: 0, to: passages.count, by: batchSize) {
            let batch = Array(passages[batchStart..<min(batchStart + batchSize, passages.count)])
            let vectors = try await embedder.embed(batch.map(\.text), as: .passage)
            embedded += zip(batch, vectors).map { EmbeddedPassage(passage: $0, vector: $1, model: embedder.modelID) }
        }
        return embedded
    }
}
