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

    public func searchTranscripts(_ query: String, limit: Int) async throws -> [SearchHit] {
        let terms = SearchTerms(query)
        // Ranking every match by relevance was the dominant cost for very common
        // words (165 ms for "the" over 200 hours). Stopword-only queries are
        // returned unranked, which lets SQLite stop after `limit` rows.
        let rank = !terms.isStopwordsOnly
        // FTS5Pattern quotes each word, so user input can't inject FTS5 syntax
        // (AND, NEAR, quotes, *); it returns nil when there are no words.
        guard limit > 0, let pattern = FTS5Pattern(matchingAllPrefixesIn: terms.searched.joined(separator: " "))
        else { return [] }
        return try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.lectureId, s.startMs, l.title,
                       highlight(transcriptSegment_ft, 0, char(1), char(2)) AS marked,
                       bm25(transcriptSegment_ft) AS rank
                FROM transcriptSegment_ft
                JOIN transcriptSegment s ON s.rowid = transcriptSegment_ft.rowid
                JOIN lecture l ON l.id = s.lectureId
                WHERE transcriptSegment_ft MATCH ?
                \(rank ? "ORDER BY rank" : "")
                LIMIT ?
                """, arguments: [pattern, limit])
            .map { row in
                let lectureID: String = row["lectureId"]
                let segmentID: String = row["id"]
                guard let lecture = UUID(uuidString: lectureID), let segment = UUID(uuidString: segmentID) else {
                    throw StorageCorruption.invalidID(UUID(uuidString: lectureID) == nil ? lectureID : segmentID)
                }
                return SearchHit(
                    lectureID: lecture,
                    lectureTitle: row["title"],
                    segmentID: segment,
                    start: LectureTime(milliseconds: row["startMs"]),
                    fragments: Self.fragments(fromHighlighted: row["marked"]),
                    // bm25 is lower for better matches; flip it so higher is better.
                    score: -(row["rank"] as Double)
                )
            }
        }
    }

    /// Splits FTS5 `highlight()` output, where matches are wrapped in \u{1}…\u{2}.
    static func fragments(fromHighlighted marked: String) -> [SearchHit.Fragment] {
        var fragments: [SearchHit.Fragment] = []
        var isMatch = false
        var current = ""
        for character in marked {
            if character == "\u{1}" || character == "\u{2}" {
                if !current.isEmpty { fragments.append(SearchHit.Fragment(text: current, isMatch: isMatch)) }
                current = ""
                isMatch = character == "\u{1}"
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { fragments.append(SearchHit.Fragment(text: current, isMatch: isMatch)) }
        return fragments
    }

    public func deleteLecture(_ lectureID: Lecture.ID) async throws {
        // Segments and the summary are removed by ON DELETE CASCADE foreign keys.
        _ = try await database.write { db in
            try LectureRecord.deleteOne(db, key: lectureID.uuidString)
        }
    }
}
