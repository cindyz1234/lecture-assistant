import Shared

/// One summary point linked back to the part of the lecture it covers.
public struct SummaryItem: Sendable, Hashable, Codable {
    public var text: String
    public var start: LectureTime
    public var end: LectureTime

    public init(text: String, start: LectureTime, end: LectureTime) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Summarizes a transcript while preserving timestamps.
///
/// Phase 3 adds an on-device 4-bit LLM (MLX Swift) with map-reduce over chunks.
public protocol Summarizer: Sendable {
    func summarize(_ segments: [TranscriptSegment]) async throws -> [SummaryItem]
}
