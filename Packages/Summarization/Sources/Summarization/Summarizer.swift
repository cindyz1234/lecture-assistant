import Shared

/// Summarizes a transcript while preserving timestamps.
public protocol Summarizer: Sendable {
    /// - Parameter progress: Called with (completed steps, total steps).
    func summarize(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> LectureSummary
}

/// Generates text from a prompt, e.g. with an on-device LLM.
public protocol TextGenerator: Sendable {
    /// - Parameters:
    ///   - instructions: System prompt describing the task.
    ///   - prompt: The user message.
    ///   - maxTokens: Upper bound on generated tokens.
    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String
}
