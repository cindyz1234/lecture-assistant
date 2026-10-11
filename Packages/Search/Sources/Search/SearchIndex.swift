import Shared

/// Semantic search across lectures (planned).
///
/// Keyword search is implemented in `Storage` (`LectureStore.searchTranscripts`)
/// because its FTS5 index lives in the lecture database and is kept in sync by
/// triggers. This package is for embedding-based search and hybrid ranking.
public protocol SearchIndex: Sendable {
    func index(_ segments: [TranscriptSegment], lectureID: Lecture.ID) async throws
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
}
