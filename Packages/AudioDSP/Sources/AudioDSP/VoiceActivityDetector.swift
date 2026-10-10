import Shared

/// Classifies audio as speech or non-speech so silent stretches can skip ASR.
///
/// Phase 2 replaces this Swift placeholder with a C++ implementation
/// (resampling, VAD, ring buffer) exposed through Swift/C++ interop.
public protocol VoiceActivityDetector: Sendable {
    /// Returns `true` if the chunk likely contains speech.
    func containsSpeech(_ chunk: AudioChunk) -> Bool
}
