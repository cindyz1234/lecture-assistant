/// What a text is, for embedding models that encode queries and passages differently.
public enum EmbeddingRole: Sendable {
    case query
    case passage
}

/// Turns texts into vectors whose cosine similarity reflects similar meaning.
public protocol TextEmbedder: Sendable {
    /// Identifies the model, so stored vectors from a different model aren't mixed in.
    var modelID: String { get }
    /// One L2-normalized vector per text, in order.
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]]
}
