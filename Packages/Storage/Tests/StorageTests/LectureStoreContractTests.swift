import Foundation
import Shared
import Testing
@testable import Storage

/// Behavior every `LectureStore` must have. Each test runs against every implementation.
struct LectureStoreContractTests {
    enum Implementation: String, CaseIterable, CustomTestStringConvertible {
        case inMemory
        case sqlite

        func makeStore() throws -> any LectureStore {
            switch self {
            case .inMemory: InMemoryLectureStore()
            case .sqlite: try SQLiteLectureStore.inMemory()
            }
        }

        var testDescription: String { rawValue }
    }

    @Test(arguments: Implementation.allCases)
    func roundTripsAllLectureFields(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(
            title: "18.06 Lecture 21: Eigenvalues",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: LectureTime(milliseconds: 3_000_500),
            status: .interrupted,
            sourceFileName: "lec21.mp4"
        )
        try await store.save(lecture)

        #expect(try await store.lectures() == [lecture])
    }

    @Test(arguments: Implementation.allCases)
    func saveUpdatesExistingLecture(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        var lecture = Lecture(title: "Draft", createdAt: date(0), status: .transcribing)
        try await store.save(lecture)

        lecture.status = .complete
        lecture.duration = LectureTime(milliseconds: 60_000)
        try await store.save(lecture)

        #expect(try await store.lectures() == [lecture])
    }

    @Test(arguments: Implementation.allCases)
    func listsNewestLectureFirst(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        try await store.save(Lecture(title: "Old", createdAt: date(0)))
        try await store.save(Lecture(title: "New", createdAt: date(100)))

        #expect(try await store.lectures().map(\.title) == ["New", "Old"])
    }

    @Test(arguments: Implementation.allCases)
    func returnsSegmentsOrderedByStartTime(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(title: "L1", createdAt: date(0))
        try await store.save(lecture)

        try await store.append([segment(at: 2_000), segment(at: 0)], to: lecture.id)
        try await store.append([segment(at: 1_000)], to: lecture.id)

        let segments = try await store.segments(for: lecture.id)
        #expect(segments.map(\.start.milliseconds) == [0, 1_000, 2_000])
        #expect(segments.map(\.text) == ["t0", "t1000", "t2000"])
        #expect(segments.allSatisfy { $0.isFinal })
    }

    @Test(arguments: Implementation.allCases)
    func keepsSegmentsOfDifferentLecturesSeparate(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let first = Lecture(title: "A", createdAt: date(0))
        let second = Lecture(title: "B", createdAt: date(1))
        try await store.save(first)
        try await store.save(second)

        try await store.append([segment(at: 0)], to: first.id)
        try await store.append([segment(at: 5_000), segment(at: 6_000)], to: second.id)

        #expect(try await store.segments(for: first.id).count == 1)
        #expect(try await store.segments(for: second.id).count == 2)
    }

    @Test(arguments: Implementation.allCases)
    func rejectsSegmentsForUnknownLecture(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let missing = UUID()

        await #expect(throws: LectureStoreError.lectureNotFound(missing)) {
            try await store.append([segment(at: 0)], to: missing)
        }
        await #expect(throws: LectureStoreError.lectureNotFound(missing)) {
            _ = try await store.segments(for: missing)
        }
    }

    @Test(arguments: Implementation.allCases)
    func deletingLectureAlsoDeletesItsSegments(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(title: "L1", createdAt: date(0))
        try await store.save(lecture)
        try await store.append([segment(at: 0), segment(at: 1_000)], to: lecture.id)

        try await store.deleteLecture(lecture.id)
        #expect(try await store.lectures().isEmpty)

        // Re-creating the same lecture must not resurrect its old segments.
        try await store.save(lecture)
        #expect(try await store.segments(for: lecture.id).isEmpty)
    }

    @Test(arguments: Implementation.allCases)
    func deletingUnknownLectureIsNoOp(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        try await store.deleteLecture(UUID())
    }
}

func date(_ secondsSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: secondsSince1970)
}

func segment(at ms: Int64) -> TranscriptSegment {
    TranscriptSegment(
        text: "t\(ms)",
        start: LectureTime(milliseconds: ms),
        end: LectureTime(milliseconds: ms + 1_000),
        isFinal: true
    )
}
