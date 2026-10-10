import ArgumentParser
import AudioCapture
import Foundation
import Shared
import Transcription
import WhisperKitTranscription

/// Transcribes audio/video files with the same pipeline the app uses, for evaluation.
///
/// For each input `<name>.<ext>` it writes `<out>/<name>.txt` (one segment per
/// line) and appends a row to `<out>/timings.csv`.
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
        let timings = try TimingsLog(url: outDirectory.appendingPathComponent("timings.csv"))

        let clock = ContinuousClock()
        let loadStart = clock.now
        let transcriber = try await WhisperKitWindowTranscriber.load(model: model)
        log("Loaded \(model) in \(format(clock.now - loadStart))")

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
            var lines: [String] = []
            for try await segment in engine.transcribe(source.chunks()) {
                lines.append(segment.text)
            }
            let elapsed = clock.now - started
            let audio = try await source.duration()

            try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
            let rtf = elapsed.seconds / audio.seconds
            try timings.append(name: name, model: model, window: window, audio: audio, elapsed: elapsed, rtf: rtf)
            log("\(name): \(audio) of audio in \(format(elapsed)) (RTF \(String(format: "%.3f", rtf))), \(lines.count) segments")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.1fs", duration.seconds)
    }
}

/// Appends one CSV row per transcribed file, writing the header for a new file.
struct TimingsLog {
    let url: URL

    init(url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try "lecture_id,model,window_s,audio_s,elapsed_s,rtf,device,date\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func append(name: String, model: String, window: Int, audio: LectureTime, elapsed: Duration, rtf: Double) throws {
        let row = [
            name, model, String(window),
            String(format: "%.1f", audio.seconds),
            String(format: "%.2f", elapsed.seconds),
            String(format: "%.4f", rtf),
            Self.deviceModel(),
            ISO8601DateFormatter().string(from: Date()),
        ].map(Self.csvField).joined(separator: ",") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(row.utf8))
    }

    /// Quotes a field if it contains a comma, quote or newline (RFC 4180).
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Hardware model identifier, e.g. "Mac15,6".
    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
