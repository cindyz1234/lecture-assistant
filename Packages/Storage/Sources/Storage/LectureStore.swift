import Foundation
import Shared

/// Persists lectures and their transcripts.
///
/// `SQLiteLectureStore` is the on-disk implementation; `InMemoryLectureStore`
/// backs previews. Both pass the same contract tests.
public protocol LectureStore: Sendable {
    /// Inserts the lecture, or updates it if one with the same ID exists.
    func save(_ lecture: Lecture) async throws
    /// All lectures, newest first.
    func lectures() async throws -> [Lecture]
    func append(_ segments: [TranscriptSegment], to lectureID: Lecture.ID) async throws
    /// Segments for a lecture, ordered by start time.
    func segments(for lectureID: Lecture.ID) async throws -> [TranscriptSegment]
    /// Deletes the lecture, its segments and its summary. Does nothing if it doesn't exist.
    func deleteLecture(_ lectureID: Lecture.ID) async throws
    /// Saves the lecture's summary, replacing any previous one.
    func saveSummary(_ summary: LectureSummary, for lectureID: Lecture.ID) async throws
    /// The lecture's summary, or `nil` if it hasn't been summarized.
    func summary(for lectureID: Lecture.ID) async throws -> LectureSummary?
}

public enum LectureStoreError: Error, Equatable {
    case lectureNotFound(Lecture.ID)
}

public actor InMemoryLectureStore: LectureStore {
    private var lecturesByID: [Lecture.ID: Lecture] = [:]
    private var segmentsByLecture: [Lecture.ID: [TranscriptSegment]] = [:]
    private var summariesByLecture: [Lecture.ID: LectureSummary] = [:]

    public init() {}

    public func save(_ lecture: Lecture) {
        lecturesByID[lecture.id] = lecture
    }

    public func lectures() -> [Lecture] {
        lecturesByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func append(_ segments: [TranscriptSegment], to lectureID: Lecture.ID) throws {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        segmentsByLecture[lectureID, default: []].append(contentsOf: segments)
    }

    public func segments(for lectureID: Lecture.ID) throws -> [TranscriptSegment] {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        return (segmentsByLecture[lectureID] ?? []).sorted { $0.start < $1.start }
    }

    public func deleteLecture(_ lectureID: Lecture.ID) {
        lecturesByID[lectureID] = nil
        segmentsByLecture[lectureID] = nil
        summariesByLecture[lectureID] = nil
    }

    public func saveSummary(_ summary: LectureSummary, for lectureID: Lecture.ID) throws {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        summariesByLecture[lectureID] = summary
    }

    public func summary(for lectureID: Lecture.ID) throws -> LectureSummary? {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        return summariesByLecture[lectureID]
    }
}
