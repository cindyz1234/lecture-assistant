import Shared

/// Produces lecture audio as a sequence of mono chunks on the lecture timeline.
///
/// Implementations: `FileAudioSource` (imported files) and, later, a microphone
/// source. Downstream stages (DSP, ASR) depend only on this protocol.
public protocol AudioSource: Sendable {
    /// Starts producing audio. Each call returns an independent stream that
    /// begins at `LectureTime.zero`. Cancelling the consuming task stops it.
    func chunks() -> AsyncThrowingStream<AudioChunk, any Error>
}
