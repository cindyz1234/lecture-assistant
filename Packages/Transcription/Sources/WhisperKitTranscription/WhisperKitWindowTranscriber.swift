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

    private init(whisperKit: WhisperKit, language: String?) {
        self.whisperKit = whisperKit
        self.decodeOptions = DecodingOptions(
            language: language,
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
    ///   - downloadBase: Where models are cached. Defaults to `defaultModelDirectory()`.
    ///   - progress: Download progress in `0...1`.
    public static func load(
        model: String,
        language: String? = "en",
        downloadBase: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> WhisperKitWindowTranscriber {
        let downloadBase = try downloadBase ?? defaultModelDirectory()
        let modelFolder = try await WhisperKit.download(variant: model, downloadBase: downloadBase) { downloadProgress in
            progress?(downloadProgress.fractionCompleted)
        }
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        return WhisperKitWindowTranscriber(whisperKit: whisperKit, language: language)
    }

    /// `Application Support/LectureAssistant/Models`, excluded from backups.
    ///
    /// WhisperKit's own default is `Documents/huggingface`, which iOS backs up to
    /// iCloud and which on macOS (outside the sandbox) is the user's Documents folder.
    public static func defaultModelDirectory() throws -> URL {
        var directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LectureAssistant/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Models can be downloaded again, so don't spend the user's backup space on them.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
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
