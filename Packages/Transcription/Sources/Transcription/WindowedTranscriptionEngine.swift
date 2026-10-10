import Shared

/// A transcribed span of text with times relative to the start of its window.
public struct WindowSegment: Sendable, Equatable {
    public var text: String
    public var start: LectureTime
    public var end: LectureTime

    public init(text: String, start: LectureTime, end: LectureTime) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Transcribes one fixed window of 16 kHz mono audio, e.g. with a Whisper model.
public protocol AudioWindowTranscriber: Sendable {
    func transcribe(window: [Float]) async throws -> [WindowSegment]
}

public enum WindowedTranscriptionError: Error, Equatable {
    case unsupportedSampleRate(Double)
}

/// Streams audio through an `AudioWindowTranscriber` one window at a time.
///
/// Incoming chunks are buffered until a full window is available. When a window
/// produces more than one segment, the last segment is assumed to be cut off by
/// the window boundary: it is not emitted, and its audio is carried over to the
/// start of the next window instead. Remaining audio is flushed when the input ends.
public struct WindowedTranscriptionEngine<Transcriber: AudioWindowTranscriber>: TranscriptionEngine {
    public static var sampleRate: Double { 16_000 }

    public let transcriber: Transcriber
    public let windowSamples: Int

    /// - Parameter windowDuration: Audio per model call. Whisper is trained on
    ///   30 s windows; shorter windows lower caption latency at some cost in accuracy.
    ///   Below ~10 s Whisper sometimes returns no text for a window that starts
    ///   mid-word, losing that audio (see docs/DESIGN.md).
    public init(transcriber: Transcriber, windowDuration: Duration = .seconds(30)) {
        let (seconds, attoseconds) = windowDuration.components
        let windowSeconds = Double(seconds) + Double(attoseconds) / 1e18
        precondition(windowSeconds > 0, "windowDuration must be positive")
        self.transcriber = transcriber
        self.windowSamples = Int(windowSeconds * Self.sampleRate)
    }

    public func transcribe(_ audio: AsyncThrowingStream<AudioChunk, any Error>) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        let transcriber = transcriber
        let windowSamples = windowSamples
        return AsyncThrowingStream { continuation in
            let task = Task {
                var window = WindowBuffer(transcriber: transcriber, windowSamples: windowSamples, sampleRate: Self.sampleRate)
                do {
                    for try await chunk in audio {
                        guard chunk.sampleRate == Self.sampleRate else {
                            throw WindowedTranscriptionError.unsupportedSampleRate(chunk.sampleRate)
                        }
                        window.append(chunk)
                        while window.hasFullWindow {
                            for segment in try await window.transcribeNext(isFinal: false) {
                                continuation.yield(segment)
                            }
                        }
                    }
                    while !window.isEmpty {
                        for segment in try await window.transcribeNext(isFinal: true) {
                            continuation.yield(segment)
                        }
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

/// Audio waiting to be transcribed, positioned on the lecture timeline.
private struct WindowBuffer<Transcriber: AudioWindowTranscriber> {
    let transcriber: Transcriber
    let windowSamples: Int
    let sampleRate: Double

    private var samples: [Float] = []
    /// Lecture sample index of `samples[0]`.
    private var startSample: Int64 = 0

    init(transcriber: Transcriber, windowSamples: Int, sampleRate: Double) {
        self.transcriber = transcriber
        self.windowSamples = windowSamples
        self.sampleRate = sampleRate
    }

    var isEmpty: Bool { samples.isEmpty }
    var hasFullWindow: Bool { samples.count >= windowSamples }

    mutating func append(_ chunk: AudioChunk) {
        if samples.isEmpty {
            startSample = chunk.start.milliseconds * Int64(sampleRate) / 1000
        }
        samples.append(contentsOf: chunk.samples)
    }

    /// Transcribes up to one window from the front of the buffer and removes the
    /// audio it covered. Returns segments on the lecture timeline.
    mutating func transcribeNext(isFinal: Bool) async throws -> [TranscriptSegment] {
        let window = Array(samples.prefix(windowSamples))
        let segments = try await transcriber.transcribe(window: window)
            .filter { !$0.text.allSatisfy(\.isWhitespace) }

        var emitted = segments[...]
        var consumed = window.count
        if !isFinal, segments.count > 1, let last = segments.last {
            let carryFrom = min(window.count, Int(last.start.milliseconds * Int64(sampleRate) / 1000))
            if carryFrom > 0 {
                emitted = segments.dropLast()
                consumed = carryFrom
            }
        }

        let offset = LectureTime(sampleIndex: startSample, sampleRate: sampleRate)
        let result = emitted.map {
            TranscriptSegment(text: $0.text, start: offset + $0.start, end: offset + $0.end, isFinal: true)
        }
        samples.removeFirst(consumed)
        startSample += Int64(consumed)
        return result
    }
}
