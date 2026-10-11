import ArgumentParser
import AudioCapture
import Foundation
import Shared
import ToolSupport
import Transcription
import WhisperKitTranscription

/// Transcribes audio/video files with the same pipeline the app uses, for evaluation.
///
/// For each input `<name>.<ext>` it writes `<out>/<name>.txt` (one segment per
/// line, for WER), `<out>/<name>.segments.json` (segments with timestamps, for
/// summarization) and appends a row to `<out>/timings.csv`.
@main
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe lecture files with the app's on-device pipeline.",
        discussion: """
        Example:
          swift run -c release --package-path Tools transcribe \\
            --model base.en --out ml/eval/outputs/base.en ml/data/processed/*.wav

        Score the output with ml/eval/wer.py. Use a release build: debug builds
        are much slower and would distort the timings.
        """
    )

    @Option(help: "WhisperKit model variant, e.g. base.en or small.en.")
    var model = "base.en"

    @Option(help: "Local WhisperKit model folder (e.g. a fine-tuned model); overrides --model.")
    var modelFolder: String?

    @Option(help: "Retries for low-confidence windows (WhisperKit default 5). They sample randomly, so use 0 for repeatable results.")
    var temperatureFallback = WhisperKitWindowTranscriber.defaultTemperatureFallbackCount

    @Option(help: "Seconds of audio per model call (the app uses 30 for files).")
    var window = 30

    @Option(help: "Directory for transcripts and timings.csv.")
    var out: String

    @Flag(help: "Re-transcribe files that already have a transcript.")
    var overwrite = false

    @Argument(help: "Audio or video files to transcribe.")
    var files: [String]

    func run() async throws {
        let outDirectory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let timings = try CSVLog(
            url: outDirectory.appendingPathComponent("timings.csv"),
            header: ["lecture_id", "model", "fallback", "window_s", "audio_s", "elapsed_s", "rtf", "device", "date"]
        )

        let clock = ContinuousClock()
        let loadStart = clock.now
        let modelName = modelFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? model
        let transcriber = if let modelFolder {
            try await WhisperKitWindowTranscriber.load(
                modelFolder: URL(fileURLWithPath: modelFolder), temperatureFallbackCount: temperatureFallback)
        } else {
            try await WhisperKitWindowTranscriber.load(model: model, temperatureFallbackCount: temperatureFallback)
        }
        log("Loaded \(modelName) (temperature fallback \(temperatureFallback)) in \(format(clock.now - loadStart))")

        for path in files {
            let input = URL(fileURLWithPath: path)
            let name = input.deletingPathExtension().lastPathComponent
            let output = outDirectory.appendingPathComponent("\(name).txt")
            if !overwrite, FileManager.default.fileExists(atPath: output.path) {
                log("\(name): exists, skipping (use --overwrite)")
                continue
            }

            let source = FileAudioSource(url: input)
            let engine = WindowedTranscriptionEngine(transcriber: transcriber, windowDuration: .seconds(window))
            let started = clock.now
            var segments: [TranscriptSegment] = []
            for try await segment in engine.transcribe(source.chunks()) {
                segments.append(segment)
            }
            let lines = segments.map(\.text)
            let elapsed = clock.now - started
            let audio = try await source.duration()

            try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(segments).write(to: outDirectory.appendingPathComponent("\(name).segments.json"))
            let rtf = elapsed.seconds / audio.seconds
            try timings.append([
                name, modelName, String(temperatureFallback), String(window),
                String(format: "%.1f", audio.seconds),
                String(format: "%.2f", elapsed.seconds),
                String(format: "%.4f", rtf),
                Machine.model(),
                Machine.timestamp(),
            ])
            log("\(name): \(audio) of audio in \(format(elapsed)) (RTF \(String(format: "%.3f", rtf))), \(lines.count) segments")
        }
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.1fs", duration.seconds)
    }
}
