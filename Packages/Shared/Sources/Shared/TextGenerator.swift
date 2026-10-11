/// Generates text from a prompt, e.g. with an on-device LLM.
public protocol TextGenerator: Sendable {
    /// - Parameters:
    ///   - instructions: System prompt describing the task.
    ///   - prompt: The user message.
    ///   - maxTokens: Upper bound on generated tokens.
    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String
}
