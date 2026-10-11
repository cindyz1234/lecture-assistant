import Accelerate

/// Exact nearest-neighbor search by cosine similarity over normalized vectors.
///
/// A library of 100 hours is ~12,000 passages × 384 dimensions (~18 MB), small
/// enough to compare against every vector; no approximate index is needed.
public struct VectorIndex: Sendable {
    public let dimension: Int
    public private(set) var count = 0
    /// Row-major matrix of normalized vectors.
    private var storage: [Float] = []

    public init(dimension: Int) {
        precondition(dimension > 0, "dimension must be positive")
        self.dimension = dimension
    }

    /// Adds a vector (normalized here, so callers don't have to); returns its row.
    @discardableResult
    public mutating func add(_ vector: [Float]) -> Int {
        precondition(vector.count == dimension, "expected \(dimension) dimensions, got \(vector.count)")
        storage.append(contentsOf: Self.normalized(vector))
        count += 1
        return count - 1
    }

    /// The stored (normalized) vector for `row`, e.g. to build a smaller index from a subset.
    public func vector(at row: Int) -> [Float] {
        precondition(row >= 0 && row < count, "row \(row) out of range")
        return Array(storage[(row * dimension)..<((row + 1) * dimension)])
    }

    /// The `k` rows most similar to `query`, best first, with cosine similarities.
    public func nearest(to query: [Float], k: Int) -> [(row: Int, similarity: Float)] {
        precondition(query.count == dimension, "expected \(dimension) dimensions, got \(query.count)")
        guard count > 0, k > 0 else { return [] }
        let normalizedQuery = Self.normalized(query)
        var similarities = [Float](repeating: 0, count: count)
        // similarities (count × 1) = storage (count × dimension) · query (dimension × 1)
        vDSP_mmul(storage, 1, normalizedQuery, 1, &similarities, 1,
                  vDSP_Length(count), 1, vDSP_Length(dimension))
        return similarities.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(k)
            .map { (row: $0.offset, similarity: $0.element) }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
