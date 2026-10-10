import Foundation
import GRDB
import Shared

// Row types that mirror the tables in `Schema` one-to-one. They are internal so
// GRDB never leaks into the rest of the app, which uses the `Shared` models.

struct LectureRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lecture"

    var id: String
    var title: String
    var createdAt: Date
    var durationMs: Int64
    var status: String
    var sourceFileName: String?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    init(_ lecture: Lecture) {
        id = lecture.id.uuidString
        title = lecture.title
        createdAt = lecture.createdAt
        durationMs = lecture.duration.milliseconds
        status = lecture.status.rawValue
        sourceFileName = lecture.sourceFileName
    }

    func model() throws -> Lecture {
        guard let uuid = UUID(uuidString: id) else { throw StorageCorruption.invalidID(id) }
        return Lecture(
            id: uuid,
            title: title,
            createdAt: createdAt,
            duration: LectureTime(milliseconds: durationMs),
            // An unknown status (e.g. written by a newer app version) reads as interrupted.
            status: Lecture.Status(rawValue: status) ?? .interrupted,
            sourceFileName: sourceFileName
        )
    }
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptSegment"

    var id: String
    var lectureId: String
    var text: String
    var startMs: Int64
    var endMs: Int64

    enum Columns {
        static let lectureId = Column(CodingKeys.lectureId)
        static let startMs = Column(CodingKeys.startMs)
    }

    init(_ segment: TranscriptSegment, lectureID: Lecture.ID) {
        id = segment.id.uuidString
        lectureId = lectureID.uuidString
        text = segment.text
        startMs = segment.start.milliseconds
        endMs = segment.end.milliseconds
    }

    /// Only final segments are stored, so `isFinal` is always `true` on read.
    func model() throws -> TranscriptSegment {
        guard let uuid = UUID(uuidString: id) else { throw StorageCorruption.invalidID(id) }
        return TranscriptSegment(
            id: uuid,
            text: text,
            start: LectureTime(milliseconds: startMs),
            end: LectureTime(milliseconds: endMs),
            isFinal: true
        )
    }
}

enum StorageCorruption: Error, Equatable {
    case invalidID(String)
}
