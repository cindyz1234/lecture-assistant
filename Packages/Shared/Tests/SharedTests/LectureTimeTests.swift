import Testing
@testable import Shared

struct LectureTimeTests {
    @Test func convertsSampleIndexToMilliseconds() {
        #expect(LectureTime(sampleIndex: 16_000, sampleRate: 16_000).milliseconds == 1_000)
        #expect(LectureTime(sampleIndex: 8, sampleRate: 16_000).milliseconds == 0)
        #expect(LectureTime(sampleIndex: 24_000, sampleRate: 16_000).milliseconds == 1_500)
    }

    @Test func formatsForDisplay() {
        #expect(LectureTime(milliseconds: 65_000).description == "1:05")
        #expect(LectureTime(milliseconds: 3_725_000).description == "1:02:05")
    }

    @Test func audioChunkEndIsStartPlusDuration() {
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 16_000),
            sampleRate: 16_000,
            start: LectureTime(milliseconds: 2_000)
        )
        #expect(chunk.end.milliseconds == 3_000)
    }
}
