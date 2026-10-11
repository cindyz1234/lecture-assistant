import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import MLXSupport
import Search
import Shared
import Tokenizers

/// Runs a sentence-embedding model on-device with MLX behind `TextEmbedder`.
public struct MLXTextEmbedder: TextEmbedder {
    /// An embedding model plus the instruction its authors prepend to queries.
    public struct Model: Sendable {
        public let configuration: ModelConfiguration
        public let queryPrefix: String

        /// BAAI bge-small-en-v1.5: 33M parameters, 384 dimensions (~130 MB).
        public static let bgeSmall = Model(
            configuration: EmbedderRegistry.bge_small,
            queryPrefix: "Represent this sentence for searching relevant passages: "
        )
        /// sentence-transformers all-MiniLM-L6-v2: 22M parameters, 384 dimensions (~90 MB).
        public static let miniLM = Model(configuration: EmbedderRegistry.minilm_l6, queryPrefix: "")
    }

    /// BERT-style models accept at most 512 tokens.
    static let maxTokens = 512

    public let modelID: String
    private let container: EmbedderModelContainer
    private let queryPrefix: String

    private init(container: EmbedderModelContainer, model: Model) {
        self.container = container
        self.modelID = model.configuration.name
        self.queryPrefix = model.queryPrefix
    }

    /// Downloads the model on first use (cached in `ModelStorage`), then loads it.
    public static func load(_ model: Model = .bgeSmall, progress: (@Sendable (Double) -> Void)? = nil) async throws -> MLXTextEmbedder {
        let downloader = HubDownloader(cacheDirectory: try ModelStorage.directory().appendingPathComponent("huggingface"))
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: model.configuration,
            progressHandler: { downloadProgress in progress?(downloadProgress.fractionCompleted) }
        )
        return MLXTextEmbedder(container: container, model: model)
    }

    public func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let inputs = role == .query ? texts.map { queryPrefix + $0 } : texts
        return try await container.perform { context in
            let tokens = inputs.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(Self.maxTokens)) }
            let width = tokens.map(\.count).max() ?? 0
            // Pad with 0 and build the attention mask from each text's real length
            // (comparing against a pad/EOS id can also mask real tokens).
            let ids = MLXArray(tokens.flatMap { $0 + Array(repeating: 0, count: width - $0.count) }.map(Int32.init))
                .reshaped(tokens.count, width)
            let mask = MLXArray(tokens.flatMap { Array(repeating: Int32(1), count: $0.count) + Array(repeating: 0, count: width - $0.count) })
                .reshaped(tokens.count, width)
            let output = context.model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids), attentionMask: mask)
            let pooled = context.pooling(output, mask: mask, normalize: true)
            pooled.eval()
            // Without the model's pooling config, pooling falls back to "none" and
            // returns one vector per token; fail loudly rather than return garbage.
            guard pooled.ndim == 2, pooled.dim(0) == tokens.count else {
                throw EmbedderError.unexpectedOutputShape(pooled.shape)
            }
            return (0..<tokens.count).map { pooled[$0].asArray(Float.self) }
        }
    }
}

public enum EmbedderError: Error, Equatable {
    case unexpectedOutputShape([Int])
}
