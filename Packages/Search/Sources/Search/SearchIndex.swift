import Shared

/// A search result pointing at a moment in a lecture.
public struct SearchHit: Sendable, Hashable {
    public var lectureID: Lecture.ID
    public var segmentID: TranscriptSegment.ID
    public var start: LectureTime
    public var snippet: String
    public var score: Double

    public init(lectureID: Lecture.ID, segmentID: TranscriptSegment.ID, start: LectureTime, snippet: String, score: Double) {
        self.lectureID = lectureID
        self.segmentID = segmentID
        self.start = start
        self.snippet = snippet
        self.score = score
    }
}

/// Searches across all lectures.
///
/// Phase 4 adds FTS5 keyword search, an embedding index and hybrid ranking.
public protocol SearchIndex: Sendable {
    func index(_ segments: [TranscriptSegment], lectureID: Lecture.ID) async throws
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
}
