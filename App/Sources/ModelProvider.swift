import Foundation
import MLXSearch
import MLXSummarization

/// Loads each on-device model once and shares it.
///
/// Summaries and Q&A both use the LLM (~1 GB); loading it twice could get the
/// app terminated for memory on iPhone. A model loads on first use, and
/// concurrent callers wait for the same load.
@MainActor
final class ModelProvider {
    private var generatorTask: Task<MLXTextGenerator, any Error>?
    private var embedderTask: Task<MLXTextEmbedder, any Error>?

    /// Qwen3-4B answered more questions correctly and declined off-topic ones
    /// far more reliably (docs/RESULTS.md), but needs ~2.1 GB. iPhone stays on
    /// Qwen3-1.7B (~0.9 GB) until memory there has been measured.
    #if os(macOS)
    static let generatorModel = MLXTextGenerator.candidates["qwen3-4b"]!
    #else
    static let generatorModel = MLXTextGenerator.candidates["qwen3-1.7b"]!
    #endif

    static var generatorName: String { generatorModel.name }

    /// - Parameter progress: Download progress in `0...1` (only the first caller's is reported).
    func generator(progress: (@Sendable (Double) -> Void)? = nil) async throws -> MLXTextGenerator {
        let task = generatorTask ?? Task { try await MLXTextGenerator.load(Self.generatorModel, progress: progress) }
        generatorTask = task
        do {
            return try await task.value
        } catch {
            generatorTask = nil  // allow a retry after e.g. a failed download
            throw error
        }
    }

    func embedder(progress: (@Sendable (Double) -> Void)? = nil) async throws -> MLXTextEmbedder {
        let task = embedderTask ?? Task { try await MLXTextEmbedder.load(progress: progress) }
        embedderTask = task
        do {
            return try await task.value
        } catch {
            embedderTask = nil
            throw error
        }
    }
}
