import Foundation
import Shared
import Testing
@testable import Search

let lecture = UUID()

func segment(_ startSeconds: Int, _ endSeconds: Int, _ text: String = "words") -> TranscriptSegment {
    TranscriptSegment(text: text, start: LectureTime(milliseconds: Int64(startSeconds) * 1000),
                      end: LectureTime(milliseconds: Int64(endSeconds) * 1000), isFinal: true)
}

struct PassageBuilderTests {
    @Test func buildsOverlappingPassagesOnSegmentBoundaries() {
        // 10 s segments from 0 to 150 s.
        let segments = (0..<15).map { segment($0 * 10, $0 * 10 + 10, "s\($0)") }

        let passages = PassageBuilder.passages(segments, lectureID: lecture, length: .seconds(60), stride: .seconds(30))

        #expect(passages.map(\.start.seconds) == [0, 30, 60, 90])
        #expect(passages.map(\.end.seconds) == [60, 90, 120, 150])
        #expect(passages[0].text == "s0 s1 s2 s3 s4 s5")
        #expect(passages[1].segmentIDs == Array(segments[3...8].map(\.id)))  // overlaps passage 0 by 30 s
    }

    @Test func keepsASegmentLongerThanThePassageLength() {
        let passages = PassageBuilder.passages([segment(0, 90, "long"), segment(90, 100, "short")],
                                               lectureID: lecture, length: .seconds(60), stride: .seconds(30))

        #expect(passages.map(\.text) == ["long", "short"])
    }

    @Test func skipsBlankSegmentsAndHandlesEmptyInput() {
        #expect(PassageBuilder.passages([], lectureID: lecture).isEmpty)
        #expect(PassageBuilder.passages([segment(0, 5, "  ")], lectureID: lecture).isEmpty)
    }
}

struct VectorIndexTests {
    @Test func returnsMostSimilarVectorsFirst() {
        var index = VectorIndex(dimension: 2)
        index.add([1, 0])      // row 0
        index.add([0, 5])      // row 1 (normalized internally)
        index.add([1, 1])      // row 2

        let nearest = index.nearest(to: [2, 0.1], k: 2)

        #expect(nearest.map(\.row) == [0, 2])
        #expect(abs(nearest[0].similarity - 0.9988) < 0.001)
    }

    @Test func returnsStoredVectorsNormalized() {
        var index = VectorIndex(dimension: 2)
        index.add([3, 4])
        index.add([0, 2])

        #expect(index.vector(at: 0) == [0.6, 0.8])
        #expect(index.vector(at: 1) == [0, 1])
    }

    @Test func handlesEmptyIndexAndZeroK() {
        var index = VectorIndex(dimension: 3)
        #expect(index.nearest(to: [1, 0, 0], k: 5).isEmpty)
        index.add([1, 0, 0])
        #expect(index.nearest(to: [1, 0, 0], k: 0).isEmpty)
    }
}

/// Embeds each text as a fixed vector by keyword, so tests control semantic similarity.
struct KeywordEmbedder: TextEmbedder {
    let modelID = "fake"
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        texts.map { text in
            let lower = text.lowercased()
            return [lower.contains("eigen") ? 1 : 0, lower.contains("orbital") ? 1 : 0, lower.contains("photon") ? 1 : 0, 0.01]
        }
    }
}

struct HybridRetrieverTests {
    // Three 60 s passages (no overlap with stride 60) about different topics.
    let segments = [
        segment(0, 60, "Today eigenvalues and eigenvectors."),
        segment(60, 120, "The p orbital has m equal to zero."),
        segment(120, 180, "A photon carries momentum h over lambda."),
    ]

    func makeRetriever(keywordHits: [Int]) async throws -> HybridRetriever {
        let passages = PassageBuilder.passages(segments, lectureID: lecture, length: .seconds(60), stride: .seconds(60))
        let hits = keywordHits.map { i in
            SearchHit(lectureID: lecture, lectureTitle: "L", segmentID: segments[i].id, start: segments[i].start,
                      fragments: [], score: 1)
        }
        return try await HybridRetriever.build(passages: passages, embedder: KeywordEmbedder()) { _, _ in hits }
    }

    @Test func semanticSearchFindsParaphrases() async throws {
        let retriever = try await makeRetriever(keywordHits: [])

        let results = try await retriever.retrieve("which orbital has zero magnetic number", k: 1, mode: .semantic)

        #expect(results.map(\.passage.start.seconds) == [60])
        #expect(results[0].semanticRank == 1 && results[0].keywordRank == nil)
    }

    @Test func keywordSearchMapsSegmentHitsToPassages() async throws {
        let retriever = try await makeRetriever(keywordHits: [2, 0])

        let results = try await retriever.retrieve("anything", k: 3, mode: .keyword)

        #expect(results.map(\.passage.start.seconds) == [120, 0])
        #expect(results.map(\.keywordRank) == [1, 2])
    }

    @Test func hybridFusesBothRankings() async throws {
        // Keyword search ranks the photon passage first; semantic ranks the orbital passage first.
        let retriever = try await makeRetriever(keywordHits: [2, 1])

        let results = try await retriever.retrieve("orbital", k: 3, mode: .hybrid)

        // Orbital: keyword #2 + semantic #1 beats photon: keyword #1 + semantic #2 or lower.
        #expect(results.first?.passage.start.seconds == 60)
        #expect(results.first?.keywordRank == 2 && results.first?.semanticRank == 1)
        let expected = 1 / (60.0 + 2) + 1 / (60.0 + 1)
        #expect(abs((results.first?.score ?? 0) - expected) < 1e-9)
    }

    @Test func keywordWeightScalesTheKeywordContribution() async throws {
        var retriever = try await makeRetriever(keywordHits: [2, 1])
        retriever.keywordWeight = 0.5

        let results = try await retriever.retrieve("orbital", k: 3, mode: .hybrid)

        let expected = 0.5 / (60.0 + 2) + 1 / (60.0 + 1)
        #expect(abs((results.first?.score ?? 0) - expected) < 1e-9)
    }

    @Test func scopedRetrieverOnlyReturnsThatLecture() async throws {
        let otherLecture = UUID()
        let mine = PassageBuilder.passages(segments, lectureID: lecture, length: .seconds(60), stride: .seconds(60))
        let theirs = PassageBuilder.passages([segment(0, 60, "Orbital orbital orbital.")], lectureID: otherLecture,
                                             length: .seconds(60), stride: .seconds(60))
        let otherHit = SearchHit(lectureID: otherLecture, lectureTitle: "Other", segmentID: theirs[0].segmentIDs[0],
                                 start: .zero, fragments: [], score: 1)
        var retriever = try await HybridRetriever.build(passages: mine + theirs, embedder: KeywordEmbedder()) { _, _ in [otherHit] }
        retriever.keywordWeight = 0.25

        let scoped = retriever.scoped(to: lecture)
        let results = try await scoped.retrieve("orbital", k: 5)

        #expect(scoped.passages.count == 3 && scoped.keywordWeight == 0.25)
        #expect(results.allSatisfy { $0.passage.lectureID == lecture })
        #expect(results.first?.passage.start.seconds == 60)  // the orbital passage, by meaning
        #expect(try await retriever.retrieve("orbital", k: 5).contains { $0.passage.lectureID == otherLecture })
    }

    @Test func retrieverFromStoredPassagesMatchesFreshlyBuiltOne() async throws {
        let embedded = try await PassageIndexer.embed(segments, lectureID: lecture, embedder: KeywordEmbedder())
        let fromStorage = HybridRetriever(embedded: embedded, embedder: KeywordEmbedder()) { _, _ in [] }

        #expect(embedded.count == 3 && embedded.allSatisfy { $0.model == "fake" })
        let results = try await fromStorage.retrieve("photon", k: 1, mode: .semantic)
        #expect(results.first?.passage.text.contains("photon") == true)
    }
}
