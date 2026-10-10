import AVFoundation
import Foundation
import Shared
import Testing
@testable import AudioCapture

struct FileAudioSourceTests {
    @Test func resamplesStereoFileToMono16kChunks() async throws {
        let url = try makeSineWAV(seconds: 2.5, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        var chunks: [AudioChunk] = []
        for try await chunk in FileAudioSource(url: url, chunkDuration: .seconds(1)).chunks() {
            chunks.append(chunk)
        }

        #expect(chunks.map(\.start.milliseconds) == [0, 1_000, 2_000])
        #expect(chunks.allSatisfy { $0.sampleRate == 16_000 })
        #expect(chunks[0].samples.count == 16_000)
        #expect(chunks[1].samples.count == 16_000)

        // The resampler may pad or trim a few samples at the end of the file.
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 40_000) < 200)
    }

    @Test func realTimePacingTakesAboutAsLongAsTheAudio() async throws {
        let url = try makeSineWAV(seconds: 0.5, sampleRate: 16_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileAudioSource(url: url, chunkDuration: .milliseconds(100), pacing: .realTime)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for try await _ in source.chunks() {}
        }

        #expect(elapsed >= .milliseconds(450))
    }

    @Test func throwsForFileWithoutAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            for try await _ in FileAudioSource(url: url).chunks() {}
        }
    }
}

/// Writes a 440 Hz sine WAV to a temporary file and returns its URL.
private func makeSineWAV(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let frameCount = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount

    for channel in 0..<Int(channels) {
        let data = buffer.floatChannelData![channel]
        for frame in 0..<Int(frameCount) {
            data[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
    }

    // The file is closed when `file` is deallocated at the end of this scope.
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}
