import Foundation
import Shared
import Transcription
// WhisperKit types are not annotated for Sendable. The pipeline instance is
// confined to `WhisperKitWindowTranscriber` and only used from that actor.
@preconcurrency import WhisperKit

/// Runs a WhisperKit (Core ML) Whisper model on one audio window at a time.
public actor WhisperKitWindowTranscriber: AudioWindowTranscriber {
    private let whisperKit: WhisperKit
    private let decodeOptions: DecodingOptions

    /// WhisperKit's default number of retries for low-confidence windows.
    /// Retries sample at temperature > 0, so they make output vary between runs.
    public static let defaultTemperatureFallbackCount = 5

    private init(whisperKit: WhisperKit, language: String?, temperatureFallbackCount: Int) {
        self.whisperKit = whisperKit
        self.decodeOptions = DecodingOptions(
            language: language,
            temperatureFallbackCount: temperatureFallbackCount,
            skipSpecialTokens: true,
            // Windowing is handled by `WindowedTranscriptionEngine`.
            chunkingStrategy: ChunkingStrategy.none
        )
    }

    /// Downloads the model on first use (cached afterwards), then loads it.
    ///
    /// - Parameters:
    ///   - model: A variant from `argmaxinc/whisperkit-coreml`, e.g. `"base.en"`.
    ///   - language: Spoken language code, or `nil` to auto-detect.
    ///   - downloadBase: Where models are cached. Defaults to `ModelStorage.directory()`.
    ///   - temperatureFallbackCount: Retries for low-confidence windows; 0 makes decoding repeatable.
    ///   - progress: Download progress in `0...1`.
    public static func load(
        model: String,
        language: String? = "en",
        downloadBase: URL? = nil,
        temperatureFallbackCount: Int = defaultTemperatureFallbackCount,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> WhisperKitWindowTranscriber {
        let downloadBase = try downloadBase ?? ModelStorage.directory()
        let modelFolder = try await WhisperKit.download(variant: model, downloadBase: downloadBase) { downloadProgress in
            progress?(downloadProgress.fractionCompleted)
        }
        return try await load(modelFolder: modelFolder, language: language, temperatureFallbackCount: temperatureFallbackCount)
    }

    /// Loads a WhisperKit (Core ML) model from a local folder, e.g. a fine-tuned
    /// model converted with whisperkittools.
    public static func load(
        modelFolder: URL,
        language: String? = "en",
        temperatureFallbackCount: Int = defaultTemperatureFallbackCount
    ) async throws -> WhisperKitWindowTranscriber {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            // Otherwise WhisperKit downloads the tokenizer to Documents/huggingface.
            tokenizerFolder: try ModelStorage.directory(),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        return WhisperKitWindowTranscriber(
            whisperKit: whisperKit, language: language, temperatureFallbackCount: temperatureFallbackCount)
    }

    public func transcribe(window: [Float]) async throws -> [WindowSegment] {
        let results = try await whisperKit.transcribe(audioArray: window, decodeOptions: decodeOptions)
        return results.flatMap(\.segments).map { segment in
            WindowSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: LectureTime(milliseconds: Int64((segment.start * 1000).rounded())),
                end: LectureTime(milliseconds: Int64((segment.end * 1000).rounded()))
            )
        }
    }
}
