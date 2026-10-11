import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Shared
import Summarization
import Tokenizers

/// Runs a quantized LLM on-device with MLX (GPU) behind `TextGenerator`.
public struct MLXTextGenerator: TextGenerator {
    /// Qwen3 1.7B, 4-bit (~940 MB).
    public static let defaultModel = LLMRegistry.qwen3_1_7b_4bit

    private let container: ModelContainer

    private init(container: ModelContainer) {
        self.container = container
    }

    /// Downloads the model on first use (cached afterwards in `ModelStorage`), then loads it.
    ///
    /// - Parameter progress: Download progress in `0...1`.
    public static func load(
        _ model: ModelConfiguration = defaultModel,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MLXTextGenerator {
        let downloader = HubDownloader(cacheDirectory: try ModelStorage.directory().appendingPathComponent("huggingface"))
        let container = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: model,
            progressHandler: { downloadProgress in progress?(downloadProgress.fractionCompleted) }
        )
        return MLXTextGenerator(container: container)
    }

    public func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        // A fresh session per call: map and reduce calls must not see each other's history.
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0,  // greedy decoding, so the same transcript gives the same summary
                repetitionPenalty: 1.1
            ),
            // Qwen3's chat template otherwise starts with a reasoning ("thinking") block.
            additionalContext: ["enable_thinking": false]
        )
        return try await session.respond(to: prompt)
    }
}

/// Downloads Hugging Face snapshots into a cache directory we choose, rather
/// than the library default (`~/.cache/huggingface`).
private struct HubDownloader: MLXLMCommon.Downloader {
    let cacheDirectory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw HubDownloaderError.invalidRepositoryID(id) }
        let client = HubClient(
            host: URL(string: "https://huggingface.co")!,
            tokenProvider: .none,
            cache: HubCache(cacheDirectory: cacheDirectory)
        )
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { progress in progressHandler(progress) }
        )
    }
}

enum HubDownloaderError: Error, Equatable {
    case invalidRepositoryID(String)
}
