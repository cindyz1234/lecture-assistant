import Foundation
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
}
