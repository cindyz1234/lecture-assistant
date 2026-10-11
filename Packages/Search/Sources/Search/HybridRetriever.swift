import Shared

/// A passage returned for a question, with how each method ranked it.
public struct RetrievedPassage: Sendable, Hashable {
    public var passage: Passage
    /// Reciprocal Rank Fusion score; higher is better.
    public var score: Double
    /// 1-based rank from keyword search, if keyword search found it.
    public var keywordRank: Int?
    /// 1-based rank from semantic search, if it was among the semantic candidates.
    public var semanticRank: Int?
}

/// Finds the passages most likely to answer a question by combining keyword
/// search (exact terms, e.g. "Rydberg") with semantic search (paraphrases, e.g.
/// "how strongly is the electron held").
///
/// The two rankings are merged with Reciprocal Rank Fusion: each passage scores
/// Σ 1 / (k + rank) over the rankings it appears in. RRF only uses ranks, so the
/// two methods' scores (bm25 vs. cosine) never need to be put on one scale.
public struct HybridRetriever: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        case keyword, semantic, hybrid
    }

    public typealias KeywordSearch = @Sendable (_ query: String, _ limit: Int) async throws -> [SearchHit]

    public let passages: [Passage]
    public let index: VectorIndex
    public let embedder: any TextEmbedder
    public let keywordSearch: KeywordSearch
    /// RRF constant; 60 is the value from the original paper.
    public var rrfK: Double = 60
    /// Weight of the keyword ranking in the fusion (semantic has weight 1).
    /// Keyword search on whole questions matches many generic words, so it can
    /// help to trust it less than semantic search.
    public var keywordWeight: Double = 1
    /// How many results each method contributes before fusion.
    public var candidates = 50

    /// - Parameter index: one vector per passage, in the same order as `passages`.
    public init(passages: [Passage], index: VectorIndex, embedder: any TextEmbedder, keywordSearch: @escaping KeywordSearch) {
        precondition(passages.count == index.count, "one vector per passage")
        self.passages = passages
        self.index = index
        self.embedder = embedder
        self.keywordSearch = keywordSearch
    }

    /// Embeds `passages` and builds a retriever over them.
    public static func build(
        passages: [Passage],
        embedder: any TextEmbedder,
        batchSize: Int = 32,
        keywordSearch: @escaping KeywordSearch
    ) async throws -> HybridRetriever {
        var index: VectorIndex?
        for batchStart in stride(from: 0, to: passages.count, by: batchSize) {
            let batch = passages[batchStart..<min(batchStart + batchSize, passages.count)]
            for vector in try await embedder.embed(batch.map(\.text), as: .passage) {
                if index == nil { index = VectorIndex(dimension: vector.count) }
                index!.add(vector)
            }
        }
        return HybridRetriever(passages: passages, index: index ?? VectorIndex(dimension: 1), embedder: embedder,
                               keywordSearch: keywordSearch)
    }

    public func retrieve(_ question: String, k: Int, mode: Mode = .hybrid) async throws -> [RetrievedPassage] {
        var keywordRanks: [Int: Int] = [:]
        var semanticRanks: [Int: Int] = [:]
        if mode != .semantic {
            keywordRanks = try await keywordPassageRanks(question)
        }
        if mode != .keyword, let vector = try await embedder.embed([question], as: .query).first {
            for (rank, match) in index.nearest(to: vector, k: candidates).enumerated() {
                semanticRanks[match.row] = rank + 1
            }
        }

        let rows = Set(keywordRanks.keys).union(semanticRanks.keys)
        return rows
            .map { row in
                let keyword = keywordRanks[row].map { keywordWeight / (rrfK + Double($0)) } ?? 0
                let semantic = semanticRanks[row].map { 1 / (rrfK + Double($0)) } ?? 0
                let score = keyword + semantic
                return RetrievedPassage(passage: passages[row], score: score,
                                        keywordRank: keywordRanks[row], semanticRank: semanticRanks[row])
            }
            // Ties (e.g. equal ranks from each method) break by time, so results are stable.
            .sorted { ($0.score, $1.passage.start) > ($1.score, $0.passage.start) }
            .prefix(k)
            .map { $0 }
    }

    /// Keyword search ranks segments; a passage takes the rank of its best-ranked
    /// segment. Overlapping passages that share a segment share its rank.
    private func keywordPassageRanks(_ question: String) async throws -> [Int: Int] {
        let hits = try await keywordSearch(question, candidates)
        var ranks: [Int: Int] = [:]
        var nextRank = 1
        for hit in hits {
            let containing = passageRows(containing: hit).filter { ranks[$0] == nil }
            guard !containing.isEmpty else { continue }
            for row in containing { ranks[row] = nextRank }
            nextRank += 1
            if nextRank > candidates { break }
        }
        return ranks
    }

    private func passageRows(containing hit: SearchHit) -> [Int] {
        passages.indices.filter { passages[$0].lectureID == hit.lectureID && passages[$0].segmentIDs.contains(hit.segmentID) }
    }
}
