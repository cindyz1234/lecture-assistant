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
    func roundTripsSummaryInOrder(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(title: "L1", createdAt: date(0))
        try await store.save(lecture)
        let summary = LectureSummary(overview: "Eigenvalues.", keyPoints: [
            SummaryItem(text: "Definition", start: LectureTime(milliseconds: 5_000)),
            SummaryItem(text: "Determinant", start: LectureTime(milliseconds: 2_000)),
        ])

        #expect(try await store.summary(for: lecture.id) == nil)
        try await store.saveSummary(summary, for: lecture.id)

        // Points come back in the order they were saved, not re-sorted.
        #expect(try await store.summary(for: lecture.id) == summary)
    }

    @Test(arguments: Implementation.allCases)
    func savingSummaryReplacesPreviousOne(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(title: "L1", createdAt: date(0))
        try await store.save(lecture)
        try await store.saveSummary(LectureSummary(overview: "Old", keyPoints: [
            SummaryItem(text: "a", start: .zero), SummaryItem(text: "b", start: .zero), SummaryItem(text: "c", start: .zero),
        ]), for: lecture.id)

        let replacement = LectureSummary(overview: "New", keyPoints: [SummaryItem(text: "only", start: .zero)])
        try await store.saveSummary(replacement, for: lecture.id)

        #expect(try await store.summary(for: lecture.id) == replacement)
    }

    @Test(arguments: Implementation.allCases)
    func deletingLectureAlsoDeletesItsSummary(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let lecture = Lecture(title: "L1", createdAt: date(0))
        try await store.save(lecture)
        try await store.saveSummary(LectureSummary(overview: "S", keyPoints: [SummaryItem(text: "p", start: .zero)]), for: lecture.id)

        try await store.deleteLecture(lecture.id)
        try await store.save(lecture)

        #expect(try await store.summary(for: lecture.id) == nil)
    }

    @Test(arguments: Implementation.allCases)
    func rejectsSummaryForUnknownLecture(_ implementation: Implementation) async throws {
        let store = try implementation.makeStore()
        let missing = UUID()

        await #expect(throws: LectureStoreError.lectureNotFound(missing)) {
            try await store.saveSummary(LectureSummary(overview: "", keyPoints: []), for: missing)
        }
        await #expect(throws: LectureStoreError.lectureNotFound(missing)) {
            _ = try await store.summary(for: missing)
        }
    }

    // MARK: - Search

    /// Two lectures with a few segments, for search tests.
    private func makeSearchFixture(_ implementation: Implementation) async throws -> (any LectureStore, Lecture, Lecture) {
        let store = try implementation.makeStore()
        let linear = Lecture(title: "Linear Algebra", createdAt: date(0))
        let quantum = Lecture(title: "Quantum Physics", createdAt: date(1))
        try await store.save(linear)
        try await store.save(quantum)
        try await store.append([
            segment(at: 0, "Today we study eigenvalues of a matrix."),
            segment(at: 1_000, "The determinant tells us when a matrix is singular."),
        ], to: linear.id)
        try await store.append([
            segment(at: 5_000, "Energy eigenvalues of the hydrogen atom."),
            segment(at: 6_000, "The wave function is normalized."),
        ], to: quantum.id)
        return (store, linear, quantum)
    }

    @Test(arguments: Implementation.allCases)
    func searchFindsMatchesAcrossLectures(_ implementation: Implementation) async throws {
        let (store, linear, quantum) = try await makeSearchFixture(implementation)

        let hits = try await store.searchTranscripts("eigenvalues", limit: 10)

        #expect(Set(hits.map(\.lectureID)) == [linear.id, quantum.id])
        let quantumHit = try #require(hits.first { $0.lectureID == quantum.id })
        #expect(quantumHit.lectureTitle == "Quantum Physics")
        #expect(quantumHit.start == LectureTime(milliseconds: 5_000))
        #expect(quantumHit.text == "Energy eigenvalues of the hydrogen atom.")
    }

    @Test(arguments: Implementation.allCases)
    func searchRequiresEveryWordAndMatchesPrefixesIgnoringCase(_ implementation: Implementation) async throws {
        let (store, linear, _) = try await makeSearchFixture(implementation)

        let hits = try await store.searchTranscripts("EIGEN matr", limit: 10)

        #expect(hits.map(\.lectureID) == [linear.id])
        #expect(hits.map(\.text) == ["Today we study eigenvalues of a matrix."])
    }

    @Test(arguments: Implementation.allCases)
    func searchMarksMatchedWords(_ implementation: Implementation) async throws {
        let (store, _, _) = try await makeSearchFixture(implementation)

        let hit = try #require(try await store.searchTranscripts("hydrogen", limit: 10).first)

        #expect(hit.fragments.filter(\.isMatch).map(\.text) == ["hydrogen"])
        #expect(hit.text == "Energy eigenvalues of the hydrogen atom.")
    }

    @Test(arguments: Implementation.allCases)
    func searchWithoutWordsOrMatchesReturnsNothing(_ implementation: Implementation) async throws {
        let (store, _, _) = try await makeSearchFixture(implementation)

        #expect(try await store.searchTranscripts("", limit: 10).isEmpty)
        #expect(try await store.searchTranscripts("  ?!  ", limit: 10).isEmpty)
        #expect(try await store.searchTranscripts("spectroscopy", limit: 10).isEmpty)
        #expect(try await store.searchTranscripts("eigenvalues", limit: 0).isEmpty)
    }

    @Test(arguments: Implementation.allCases)
    func searchIgnoresStopwordsUnlessQueryHasNothingElse(_ implementation: Implementation) async throws {
        let (store, _, quantum) = try await makeSearchFixture(implementation)

        // "what" and "is" appear in no hydrogen segment, but are ignored.
        #expect(try await store.searchTranscripts("what is hydrogen", limit: 10).map(\.lectureID) == [quantum.id])
        // A stopword-only query still finds something.
        #expect(try await !store.searchTranscripts("the", limit: 10).isEmpty)
    }

    @Test(arguments: Implementation.allCases)
    func anyWordSearchMatchesSegmentsWithSomeOfTheWords(_ implementation: Implementation) async throws {
        let (store, linear, quantum) = try await makeSearchFixture(implementation)
        let question = "how is the determinant of a hydrogen spectroscopy matrix computed"

        #expect(try await store.searchTranscripts(question, limit: 10).isEmpty)  // no segment has all words
        let hits = try await store.searchTranscripts(question, limit: 10, matching: .anyWord)
        #expect(Set(hits.map(\.lectureID)) == [linear.id, quantum.id])
    }

    @Test(arguments: Implementation.allCases)
    func searchRespectsLimit(_ implementation: Implementation) async throws {
        let (store, _, _) = try await makeSearchFixture(implementation)

        #expect(try await store.searchTranscripts("the", limit: 1).count == 1)
    }

    @Test(arguments: Implementation.allCases)
    func deletedLecturesDisappearFromSearch(_ implementation: Implementation) async throws {
        let (store, linear, quantum) = try await makeSearchFixture(implementation)

        try await store.deleteLecture(quantum.id)

        #expect(try await store.searchTranscripts("eigenvalues", limit: 10).map(\.lectureID) == [linear.id])
        #expect(try await store.searchTranscripts("hydrogen", limit: 10).isEmpty)
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

func segment(at ms: Int64, _ text: String? = nil) -> TranscriptSegment {
    TranscriptSegment(
        text: text ?? "t\(ms)",
        start: LectureTime(milliseconds: ms),
        end: LectureTime(milliseconds: ms + 1_000),
        isFinal: true
    )
}
