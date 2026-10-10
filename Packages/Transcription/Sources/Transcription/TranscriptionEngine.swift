import Shared

/// Converts a stream of audio into transcript segments.
///
/// Engines may emit non-final (partial) segments that are later replaced by a
/// final segment covering the same time range.
public protocol TranscriptionEngine: Sendable {
    func transcribe(_ audio: AsyncThrowingStream<AudioChunk, any Error>) -> AsyncThrowingStream<TranscriptSegment, any Error>
}

/// Emits one final segment per audio chunk with placeholder text.
/// Used in tests and to exercise the pipeline before a real model is wired in.
public struct FakeTranscriptionEngine: TranscriptionEngine {
    public init() {}

    public func transcribe(_ audio: AsyncThrowingStream<AudioChunk, any Error>) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var index = 0
                    for try await chunk in audio {
                        continuation.yield(TranscriptSegment(
                            text: "Segment \(index)",
                            start: chunk.start,
                            end: chunk.end,
                            isFinal: true
                        ))
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
