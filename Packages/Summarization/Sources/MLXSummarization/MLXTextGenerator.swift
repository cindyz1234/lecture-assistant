import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXSupport
import Shared
import Summarization
import Tokenizers

/// Runs a quantized LLM on-device with MLX (GPU) behind `TextGenerator`.
public struct MLXTextGenerator: TextGenerator {
    /// Qwen3 1.7B, 4-bit (~940 MB).
    public static let defaultModel = LLMRegistry.qwen3_1_7b_4bit

    /// Models compared for Q&A and summaries, by short name.
    public static let candidates: [String: ModelConfiguration] = [
        "qwen3-1.7b": LLMRegistry.qwen3_1_7b_4bit,
        "qwen3-4b": LLMRegistry.qwen3_4b_4bit,
        "qwen3.5-2b": LLMRegistry.qwen3_5_2b_4bit,
    ]

    /// Hugging Face ID of the loaded model.
    public let modelID: String
    private let container: ModelContainer

    private init(container: ModelContainer, modelID: String) {
        self.container = container
        self.modelID = modelID
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
        return MLXTextGenerator(container: container, modelID: model.name)
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
