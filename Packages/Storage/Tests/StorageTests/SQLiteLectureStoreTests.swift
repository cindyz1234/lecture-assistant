import Foundation
import GRDB
import Shared
import Testing
@testable import Storage

/// Behavior specific to the on-disk store.
struct SQLiteLectureStoreTests {
    @Test func dataSurvivesReopeningTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/lectures.sqlite")
        let lecture = Lecture(title: "Persisted", createdAt: date(0), status: .complete)

        do {
            let store = try SQLiteLectureStore(url: url)
            try await store.save(lecture)
            try await store.append([segment(at: 0), segment(at: 1_000)], to: lecture.id)
        }

        let reopened = try SQLiteLectureStore(url: url)
        #expect(try await reopened.lectures() == [lecture])
        #expect(try await reopened.segments(for: lecture.id).map(\.text) == ["t0", "t1000"])
    }

    @Test func reopeningRunsMigrationsOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lectures.sqlite")

        _ = try SQLiteLectureStore(url: url)
        // Would throw "table lecture already exists" if v1 ran again.
        _ = try SQLiteLectureStore(url: url)
    }

    /// A database written by an app version that only had migration v1 must
    /// keep its lectures when the current version opens it and runs v2.
    @Test func upgradingFromV1KeepsExistingLectures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lectures.sqlite")
        let lectureID = UUID()

        do {
            let oldDatabase = try DatabaseQueue(path: url.path)
            try Schema.migrator.migrate(oldDatabase, upTo: "v1: lectures and transcript segments")
            try await oldDatabase.write { db in
                try db.execute(
                    sql: "INSERT INTO lecture (id, title, createdAt, durationMs, status) VALUES (?, ?, ?, ?, ?)",
                    arguments: [lectureID.uuidString, "Old lecture", Date(timeIntervalSince1970: 0), 60_000, "complete"]
                )
                #expect(try !db.tableExists("summary"))
            }
        }

        let store = try SQLiteLectureStore(url: url)

        #expect(try await store.lectures().map(\.title) == ["Old lecture"])
        let summary = LectureSummary(overview: "Added after upgrade", keyPoints: [])
        try await store.saveSummary(summary, for: lectureID)
        #expect(try await store.summary(for: lectureID) == summary)
    }

    // MARK: - Full-text search

    @Test func searchMatchesWordStems() async throws {
        let store = try SQLiteLectureStore.inMemory()
        let lecture = Lecture(title: "Graphs", createdAt: date(0))
        try await store.save(lecture)
        try await store.append([segment(at: 0, "These two vertices are connected.")], to: lecture.id)

        // Porter stemming: "connection" and "connected" share the stem "connect".
        // A prefix match alone would not find this.
        #expect(try await store.searchTranscripts("connection", limit: 10).count == 1)
    }

    @Test func searchRanksMoreRelevantSegmentsFirst() async throws {
        let store = try SQLiteLectureStore.inMemory()
        let lecture = Lecture(title: "L", createdAt: date(0))
        try await store.save(lecture)
        try await store.append([
            segment(at: 0, "We mention the determinant once and then move on to other topics today."),
            segment(at: 1_000, "Determinant, determinant: the determinant is zero."),
        ], to: lecture.id)

        let hits = try await store.searchTranscripts("determinant", limit: 10)

        #expect(hits.map(\.start.milliseconds) == [1_000, 0])
        #expect(hits[0].score > hits[1].score)
    }

    @Test(arguments: ["\"eigen", "eigen AND", "NEAR(eigen", "eigen*", "-eigen", "eigen OR (", "'; DROP TABLE lecture; --"])
    func searchTreatsQuerySyntaxAsPlainText(query: String) async throws {
        let store = try SQLiteLectureStore.inMemory()
        let lecture = Lecture(title: "L", createdAt: date(0))
        try await store.save(lecture)
        try await store.append([segment(at: 0, "Eigenvalues and eigenvectors.")], to: lecture.id)

        // Must not throw an FTS5 syntax error; the words are searched literally.
        _ = try await store.searchTranscripts(query, limit: 10)
        #expect(try await store.lectures().count == 1)
    }

    @Test func highlightMarkersBecomeFragments() {
        let fragments = SQLiteLectureStore.fragments(fromHighlighted: "The \u{1}eigen\u{2}values of \u{1}A\u{2}")
        #expect(fragments == [
            SearchHit.Fragment(text: "The ", isMatch: false),
            SearchHit.Fragment(text: "eigen", isMatch: true),
            SearchHit.Fragment(text: "values of ", isMatch: false),
            SearchHit.Fragment(text: "A", isMatch: true),
        ])
    }

    /// Lectures transcribed before search existed must become searchable when
    /// the v3 migration runs on an existing database.
    @Test func upgradingFromV2IndexesExistingTranscripts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lectures.sqlite")
        let lectureID = UUID()

        do {
            let oldDatabase = try DatabaseQueue(path: url.path)
            try Schema.migrator.migrate(oldDatabase, upTo: "v2: lecture summaries")
            try await oldDatabase.write { db in
                try db.execute(
                    sql: "INSERT INTO lecture (id, title, createdAt, durationMs, status) VALUES (?, ?, ?, ?, ?)",
                    arguments: [lectureID.uuidString, "Old lecture", Date(timeIntervalSince1970: 0), 60_000, "complete"]
                )
                try db.execute(
                    sql: "INSERT INTO transcriptSegment (id, lectureId, text, startMs, endMs) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString, lectureID.uuidString, "The spectral theorem.", 42_000, 45_000]
                )
            }
        }

        let store = try SQLiteLectureStore(url: url)

        let hits = try await store.searchTranscripts("spectral", limit: 10)
        #expect(hits.map(\.lectureTitle) == ["Old lecture"])
        #expect(hits.map(\.start.milliseconds) == [42_000])
    }
}
