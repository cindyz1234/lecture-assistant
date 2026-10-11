import ArgumentParser
import Foundation
import Shared
import Storage
import ToolSupport

/// Measures keyword search latency on a large lecture database.
///
/// Builds a temporary database by repeating real transcripts (`*.segments.json`
/// from `transcribe`) until it holds `--hours` of lectures, then times queries.
@main
struct SearchBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Benchmark transcript search on a synthetic library of real transcripts.",
        discussion: """
        Example:
          swift run -c release --package-path Tools searchbench --hours 100 \\
            ml/eval/outputs/base.en/*.segments.json
        """
    )

    @Option(help: "Minimum hours of lectures in the benchmark database.")
    var hours = 100.0

    @Option(help: "Timed runs per query (after one warm-up run).")
    var runs = 20

    @Option(help: "Maximum results per query, as in the app.")
    var limit = 50

    @Argument(help: "Transcript files (<name>.segments.json from `transcribe`).")
    var files: [String]

    static let queries = [
        "eigenvalue",          // common topic word
        "determinant",
        "schrodinger",         // rare
        "eigen",               // short prefix, many matches
        "the",                 // extremely common
        "wave function",       // two words
        "principal quantum number",
        "orthogonal eigenvectors symmetric",
        "xylophone",           // no matches
    ]

    func run() async throws {
        let transcripts = try files.map { path in
            try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let sourceHours = transcripts.compactMap { $0.last?.end.seconds }.reduce(0, +) / 3600
        guard sourceHours > 0 else { throw ValidationError("No segments in input files.") }
        let copies = Int((hours / sourceHours).rounded(.up))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("searchbench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteLectureStore(url: directory.appendingPathComponent("bench.sqlite"))

        let clock = ContinuousClock()
        let buildStart = clock.now
        var segmentCount = 0
        for copy in 0..<copies {
            for (index, segments) in transcripts.enumerated() {
                let lecture = Lecture(title: "Lecture \(copy)-\(index)", createdAt: Date(timeIntervalSince1970: Double(copy)))
                try await store.save(lecture)
                // Fresh segment IDs so every copy is a distinct row.
                let copied = segments.map {
                    TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, isFinal: true)
                }
                try await store.append(copied, to: lecture.id)
                segmentCount += copied.count
            }
        }
        log(String(format: "Built %.0f hours (%d lectures, %d segments) in %.1fs",
                   sourceHours * Double(copies), copies * transcripts.count, segmentCount,
                   (clock.now - buildStart).seconds))

        print("| Query | Results | p50 (ms) | p95 (ms) | Max (ms) |")
        print("|---|---:|---:|---:|---:|")
        var worstP95 = 0.0
        for query in Self.queries {
            _ = try await store.searchTranscripts(query, limit: limit)  // warm-up
            var times: [Double] = []
            var results = 0
            for _ in 0..<runs {
                let start = clock.now
                results = try await store.searchTranscripts(query, limit: limit).count
                times.append((clock.now - start).seconds * 1000)
            }
            times.sort()
            let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
            worstP95 = max(worstP95, p95)
            print(String(format: "| %@ | %d | %.1f | %.1f | %.1f |",
                         query, results, times[times.count / 2], p95, times.last!))
        }
        log(String(format: "Worst p95: %.1f ms on %@", worstP95, Machine.model()))
    }
}
