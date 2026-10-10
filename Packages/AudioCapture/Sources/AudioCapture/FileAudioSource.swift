// AVAsset/AVAssetTrack are not marked Sendable in older SDKs. They are only
// touched inside `FileAudioReader`, which confines them to one actor.
@preconcurrency import AVFoundation
import Shared

public enum FileAudioSourceError: Error, Equatable {
    case noAudioTrack
    case cannotStartReading(String)
    case readFailed(String)
}

/// Reads the audio track of a local audio or video file as 16 kHz mono chunks.
///
/// The stream is pull-based: audio is decoded only when the consumer asks for
/// the next chunk, so a slow consumer never causes unbounded buffering.
public struct FileAudioSource: AudioSource {
    public enum Pacing: Sendable {
        /// Decode as fast as the consumer pulls. Use for batch transcription.
        case asFastAsPossible
        /// Deliver each chunk no earlier than its end time relative to when
        /// streaming started, simulating a live recording.
        case realTime
    }

    /// Sample rate expected by the ASR models.
    public static let sampleRate: Double = 16_000

    public let url: URL
    public let chunkDuration: Duration
    public let pacing: Pacing

    public init(url: URL, chunkDuration: Duration = .seconds(1), pacing: Pacing = .asFastAsPossible) {
        precondition(chunkDuration > .zero, "chunkDuration must be positive")
        self.url = url
        self.chunkDuration = chunkDuration
        self.pacing = pacing
    }

    /// Length of the file's audio.
    public func duration() async throws -> LectureTime {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return LectureTime(milliseconds: Int64((duration.seconds * 1000).rounded()))
    }

    public func chunks() -> AsyncThrowingStream<AudioChunk, any Error> {
        let samplesPerChunk = max(1, Int(chunkDuration.seconds * Self.sampleRate))
        let reader = FileAudioReader(url: url, sampleRate: Self.sampleRate, samplesPerChunk: samplesPerChunk)
        let pacer: RealTimePacer? = pacing == .realTime ? RealTimePacer() : nil

        return AsyncThrowingStream {
            guard let chunk = try await reader.nextChunk() else { return nil }
            try await pacer?.wait(until: chunk.end)
            return chunk
        }
    }
}

/// Owns the non-Sendable AVFoundation reader state. Expects a single consumer.
private actor FileAudioReader {
    private let url: URL
    private let sampleRate: Double
    private let samplesPerChunk: Int

    private var assetReader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [Float] = []
    private var samplesEmitted: Int64 = 0
    private var reachedEnd = false

    init(url: URL, sampleRate: Double, samplesPerChunk: Int) {
        self.url = url
        self.sampleRate = sampleRate
        self.samplesPerChunk = samplesPerChunk
    }

    func nextChunk() async throws -> AudioChunk? {
        if output == nil {
            try await startReading()
        }
        guard let assetReader, let output else { return nil }

        while pending.count < samplesPerChunk, !reachedEnd {
            try Task.checkCancellation()
            if let sampleBuffer = output.copyNextSampleBuffer() {
                pending.append(contentsOf: try Self.samples(from: sampleBuffer))
            } else if assetReader.status == .failed {
                throw FileAudioSourceError.readFailed(assetReader.error?.localizedDescription ?? "unknown")
            } else {
                reachedEnd = true
            }
        }

        guard !pending.isEmpty else { return nil }
        let count = min(samplesPerChunk, pending.count)
        let chunk = AudioChunk(
            samples: Array(pending[..<count]),
            sampleRate: sampleRate,
            start: LectureTime(sampleIndex: samplesEmitted, sampleRate: sampleRate)
        )
        pending.removeFirst(count)
        samplesEmitted += Int64(count)
        return chunk
    }

    private func startReading() async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw FileAudioSourceError.noAudioTrack
        }

        // AVAssetReader handles decoding, downmixing to mono and resampling.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false

        let assetReader = try AVAssetReader(asset: asset)
        guard assetReader.canAdd(output) else {
            throw FileAudioSourceError.cannotStartReading("output not supported")
        }
        assetReader.add(output)
        guard assetReader.startReading() else {
            throw FileAudioSourceError.cannotStartReading(assetReader.error?.localizedDescription ?? "unknown")
        }

        self.assetReader = assetReader
        self.output = output
    }

    private static func samples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            throw FileAudioSourceError.readFailed("CMBlockBufferCopyDataBytes returned \(status)")
        }
        return samples
    }
}

/// Sleeps so that audio at lecture time `t` is released `t` after the first call.
private actor RealTimePacer {
    private let clock = ContinuousClock()
    private var startedAt: ContinuousClock.Instant?

    func wait(until time: LectureTime) async throws {
        let start = startedAt ?? clock.now
        startedAt = start
        try await Task.sleep(until: start + .milliseconds(time.milliseconds), clock: clock)
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
