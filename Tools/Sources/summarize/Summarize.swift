import ArgumentParser
import Foundation
import MLXSummarization
import Shared
import Summarization
import ToolSupport

/// Summarizes transcripts with the same summarizer the app uses, for evaluation.
///
/// Reads `<name>.segments.json` files written by `transcribe`. For each it writes
/// `<out>/<name>.summary.md` and appends a row to `<out>/summary_timings.csv`.
@main
struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Summarize transcripts with the app's on-device LLM summarizer.",
        discussion: """
        MLX compiles GPU (Metal) code, which `swift build` can't do, so build with xcodebuild:
          xcodebuild build -scheme summarize -destination platform=macOS -configuration Release \\
            -derivedDataPath Tools/.xcbuild -skipMacroValidation -skipPackagePluginValidation \\
            -workspace Tools
          Tools/.xcbuild/Build/Products/Release/summarize --out ml/eval/outputs/summaries \\
            ml/eval/outputs/base.en/*.segments.json
        """
    )

    @Option(help: "Directory for summaries and summary_timings.csv.")
    var out: String

    @Argument(help: "Transcript files (<name>.segments.json from `transcribe`).")
    var files: [String]

    func run() async throws {
        let outDirectory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let timings = try CSVLog(
            url: outDirectory.appendingPathComponent("summary_timings.csv"),
            header: ["lecture_id", "model", "words", "steps", "elapsed_s", "peak_memory_mb", "device", "date"]
        )

        let clock = ContinuousClock()
        let loadStart = clock.now
        let model = MLXTextGenerator.defaultModel
        let generator = try await MLXTextGenerator.load(model)
        log("Loaded \(model.name) in \(String(format: "%.1fs", (clock.now - loadStart).seconds))")
        let summarizer = MapReduceSummarizer(generator: generator)

        for path in files {
            let input = URL(fileURLWithPath: path)
            let name = input.lastPathComponent.replacingOccurrences(of: ".segments.json", with: "")
            let segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: input))
            let words = segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }

            let steps = StepCounter()
            let started = clock.now
            let summary = try await summarizer.summarize(segments) { done, total in
                steps.set(total)
                log("  \(name): step \(done)/\(total)")
            }
            let elapsed = clock.now - started

            try Self.markdown(name: name, summary: summary).write(
                to: outDirectory.appendingPathComponent("\(name).summary.md"), atomically: true, encoding: .utf8)
            try timings.append([
                name, model.name, String(words), String(steps.total),
                String(format: "%.2f", elapsed.seconds),
                String(format: "%.0f", Machine.peakMemoryMB()),
                Machine.model(), Machine.timestamp(),
            ])
            log("\(name): \(words) words summarized in \(String(format: "%.1fs", elapsed.seconds)), \(summary.keyPoints.count) key points")
        }
        log("Peak memory: \(String(format: "%.0f", Machine.peakMemoryMB())) MB")
    }

    static func markdown(name: String, summary: LectureSummary) -> String {
        var text = "# \(name)\n\n\(summary.overview)\n\n## Key points\n\n"
        for point in summary.keyPoints {
            text += "- **[\(point.start)]** \(point.text)\n"
        }
        return text
    }
}

/// Remembers the step total reported by the progress callback.
final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int { lock.withLock { value } }

    func set(_ total: Int) {
        lock.withLock { value = total }
    }
}
