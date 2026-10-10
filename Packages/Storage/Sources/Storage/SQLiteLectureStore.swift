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

    public func deleteLecture(_ lectureID: Lecture.ID) async throws {
        // Segments are removed by the ON DELETE CASCADE foreign key.
        _ = try await database.write { db in
            try LectureRecord.deleteOne(db, key: lectureID.uuidString)
        }
    }
}
