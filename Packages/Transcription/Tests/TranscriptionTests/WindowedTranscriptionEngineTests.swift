import Shared
import Testing
@testable import Transcription

struct WindowedTranscriptionEngineTests {
    @Test func splitsAudioIntoWindowsOnTheLectureTimeline() async throws {
        let model = ScriptedTranscriber { _, window in
            [WindowSegment(text: "speech", start: .zero, end: duration(of: window))]
        }
        let engine = WindowedTranscriptionEngine(transcriber: model, windowDuration: .seconds(10))

        let segments = try await collect(engine.transcribe(audio(seconds: 25)))

        #expect(await model.windowLengths == [160_000, 160_000, 80_000])
        #expect(segments.map(\.start.milliseconds) == [0, 10_000, 20_000])
        #expect(segments.map(\.end.milliseconds) == [10_000, 20_000, 25_000])
    }

    @Test func carriesTrailingSegmentIntoNextWindow() async throws {
        let model = ScriptedTranscriber { call, window in
            if call == 0 {
                return [
                    WindowSegment(text: "complete", start: .zero, end: ms(6_000)),
                    WindowSegment(text: "cut off", start: ms(6_000), end: ms(10_000)),
                ]
            }
            return [WindowSegment(text: "window \(call)", start: .zero, end: duration(of: window))]
        }
        let engine = WindowedTranscriptionEngine(transcriber: model, windowDuration: .seconds(10))

        let segments = try await collect(engine.transcribe(audio(seconds: 20)))

        // The second window restarts at 6 s, where the cut-off segment began.
        #expect(await model.windowLengths == [160_000, 160_000, 64_000])
        #expect(segments.map(\.text) == ["complete", "window 1", "window 2"])
        #expect(segments.map(\.start.milliseconds) == [0, 6_000, 16_000])
        #expect(!segments.map(\.text).contains("cut off"))
    }

    @Test func finalWindowEmitsAllSegments() async throws {
        let model = ScriptedTranscriber { _, _ in
            [
                WindowSegment(text: "first", start: .zero, end: ms(2_000)),
                WindowSegment(text: "last", start: ms(2_000), end: ms(5_000)),
            ]
        }
        let engine = WindowedTranscriptionEngine(transcriber: model, windowDuration: .seconds(10))

        let segments = try await collect(engine.transcribe(audio(seconds: 5)))

        #expect(segments.map(\.text) == ["first", "last"])
    }

    @Test func dropsBlankSegments() async throws {
        let model = ScriptedTranscriber { _, _ in
            [
                WindowSegment(text: "  ", start: .zero, end: ms(1_000)),
                WindowSegment(text: "hello", start: ms(1_000), end: ms(2_000)),
            ]
        }
        let engine = WindowedTranscriptionEngine(transcriber: model, windowDuration: .seconds(10))

        let segments = try await collect(engine.transcribe(audio(seconds: 2)))

        #expect(segments.map(\.text) == ["hello"])
    }

    @Test func rejectsAudioThatIsNot16kHz() async {
        let model = ScriptedTranscriber { _, _ in [] }
        let engine = WindowedTranscriptionEngine(transcriber: model)
        let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
            continuation.yield(AudioChunk(samples: [0, 0], sampleRate: 44_100, start: .zero))
            continuation.finish()
        }

        await #expect(throws: WindowedTranscriptionError.unsupportedSampleRate(44_100)) {
            _ = try await collect(engine.transcribe(audio))
        }
    }
}

/// Returns scripted segments and records the length of every window it receives.
private actor ScriptedTranscriber: AudioWindowTranscriber {
    typealias Script = @Sendable (_ call: Int, _ window: [Float]) -> [WindowSegment]

    private let script: Script
    private(set) var windowLengths: [Int] = []

    init(script: @escaping Script) {
        self.script = script
    }

    func transcribe(window: [Float]) -> [WindowSegment] {
        defer { windowLengths.append(window.count) }
        return script(windowLengths.count, window)
    }
}

private func ms(_ milliseconds: Int64) -> LectureTime {
    LectureTime(milliseconds: milliseconds)
}

private func duration(of window: [Float]) -> LectureTime {
    LectureTime(sampleIndex: Int64(window.count), sampleRate: 16_000)
}

/// Silent 16 kHz audio delivered in 1-second chunks.
private func audio(seconds: Int) -> AsyncThrowingStream<AudioChunk, any Error> {
    AsyncThrowingStream { continuation in
        for second in 0..<seconds {
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0, count: 16_000),
                sampleRate: 16_000,
                start: ms(Int64(second) * 1_000)
            ))
        }
        continuation.finish()
    }
}

private func collect(_ stream: AsyncThrowingStream<TranscriptSegment, any Error>) async throws -> [TranscriptSegment] {
    var segments: [TranscriptSegment] = []
    for try await segment in stream {
        segments.append(segment)
    }
    return segments
}
