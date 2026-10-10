import Shared
import Testing
@testable import Transcription

struct FakeTranscriptionEngineTests {
    @Test func emitsOneSegmentPerChunkWithMatchingTimestamps() async throws {
        let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
            for second in 0..<3 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0, count: 16_000),
                    sampleRate: 16_000,
                    start: LectureTime(milliseconds: Int64(second) * 1_000)
                ))
            }
            continuation.finish()
        }

        var segments: [TranscriptSegment] = []
        for try await segment in FakeTranscriptionEngine().transcribe(audio) {
            segments.append(segment)
        }

        #expect(segments.map(\.start.milliseconds) == [0, 1_000, 2_000])
        #expect(segments.map(\.end.milliseconds) == [1_000, 2_000, 3_000])
        #expect(segments.allSatisfy { $0.isFinal })
    }

    @Test func propagatesAudioErrors() async {
        struct Boom: Error {}
        let audio = AsyncThrowingStream<AudioChunk, any Error> { $0.finish(throwing: Boom()) }

        await #expect(throws: Boom.self) {
            for try await _ in FakeTranscriptionEngine().transcribe(audio) {}
        }
    }
}
