import Foundation
import GRDB
import Shared

/// `LectureStore` backed by a SQLite database file (via GRDB).
///
/// Uses a `DatabasePool` (WAL mode) for files, so the UI can read while
/// transcription writes. Every method runs in a single transaction.
public final class SQLiteLectureStore: LectureStore {
    private let database: any DatabaseWriter

    /// Opens (creating if needed) the database at `url` and runs pending migrations.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try self.init(database: DatabasePool(path: url.path, configuration: Self.configuration))
    }

    /// A private in-memory database, for tests and previews.
    public static func inMemory() throws -> SQLiteLectureStore {
        try SQLiteLectureStore(database: DatabaseQueue(configuration: configuration))
    }

    private init(database: any DatabaseWriter) throws {
        self.database = database
        try Schema.migrator.migrate(database)
    }

    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }

    /// Default location: Application Support/Lectures/lectures.sqlite.
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Lectures", isDirectory: true)
            .appendingPathComponent("lectures.sqlite")
    }

    public func save(_ lecture: Lecture) async throws {
        let record = LectureRecord(lecture)
        try await database.write { db in
            try record.save(db)
        }
    }

    public func lectures() async throws -> [Lecture] {
        try await database.read { db in
            try LectureRecord
                .order(LectureRecord.Columns.createdAt.desc)
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func append(_ segments: [TranscriptSegment], to lectureID: Lecture.ID) async throws {
        let records = segments.map { SegmentRecord($0, lectureID: lectureID) }
        try await database.write { db in
            guard try LectureRecord.exists(db, key: lectureID.uuidString) else {
                throw LectureStoreError.lectureNotFound(lectureID)
            }
            for record in records {
                try record.insert(db)
            }
        }
    }

    public func segments(for lectureID: Lecture.ID) async throws -> [TranscriptSegment] {
        try await database.read { db in
            guard try LectureRecord.exists(db, key: lectureID.uuidString) else {
                throw LectureStoreError.lectureNotFound(lectureID)
            }
            return try SegmentRecord
                .filter(SegmentRecord.Columns.lectureId == lectureID.uuidString)
                .order(SegmentRecord.Columns.startMs)
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func saveSummary(_ summary: LectureSummary, for lectureID: Lecture.ID) async throws {
        let id = lectureID.uuidString
        let record = SummaryRecord(lectureId: id, overview: summary.overview, createdAt: Date())
        let points = summary.keyPoints.enumerated().map { position, point in
            SummaryPointRecord(lectureId: id, position: position, startMs: point.start.milliseconds, text: point.text)
        }
        try await database.write { db in
            guard try LectureRecord.exists(db, key: id) else {
                throw LectureStoreError.lectureNotFound(lectureID)
            }
            // Replacing the summary row cascades to its old points.
            try SummaryRecord.deleteOne(db, key: id)
            try record.insert(db)
            for point in points {
                try point.insert(db)
            }
        }
    }

    public func summary(for lectureID: Lecture.ID) async throws -> LectureSummary? {
        let id = lectureID.uuidString
        return try await database.read { db in
            guard try LectureRecord.exists(db, key: id) else {
                throw LectureStoreError.lectureNotFound(lectureID)
            }
            guard let record = try SummaryRecord.fetchOne(db, key: id) else { return nil }
            let points = try SummaryPointRecord
                .filter(SummaryPointRecord.Columns.lectureId == id)
                .order(SummaryPointRecord.Columns.position)
                .fetchAll(db)
            return LectureSummary(overview: record.overview, keyPoints: points.map { $0.model() })
        }
    }

    public func deleteLecture(_ lectureID: Lecture.ID) async throws {
        // Segments and the summary are removed by ON DELETE CASCADE foreign keys.
        _ = try await database.write { db in
            try LectureRecord.deleteOne(db, key: lectureID.uuidString)
        }
    }
}
