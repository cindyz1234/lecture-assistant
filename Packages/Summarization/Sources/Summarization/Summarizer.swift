import Shared

/// Summarizes a transcript while preserving timestamps.
public protocol Summarizer: Sendable {
    /// - Parameter progress: Called with (completed steps, total steps).
    func summarize(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> LectureSummary
}
