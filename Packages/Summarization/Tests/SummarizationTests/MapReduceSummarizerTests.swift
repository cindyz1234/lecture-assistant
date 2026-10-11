import Foundation
import Shared
import Testing
@testable import Summarization

struct MapReduceSummarizerTests {
    /// 4 segments of 3 words; with chunkWords = 6 that is 2 chunks:
    /// chunk 1 = 0:00–0:20, chunk 2 = 1:00–1:20.
    let transcript = [
        segment(0, 10_000, "eigenvalues are special"),
        segment(10_000, 20_000, "determinant equals zero"),
        segment(60_000, 70_000, "diagonalize the matrix"),
        segment(70_000, 80_000, "powers of A"),
    ]

    typealias Summarizer = MapReduceSummarizer<ScriptedGenerator>

    var configuration: Summarizer.Configuration {
        var configuration = Summarizer.Configuration()
        configuration.chunkWords = 6
        configuration.pointsPerChunk = 2
        return configuration
    }

    @Test func keyPointsComeFromMapAndOverviewFromReduce() async throws {
        let generator = ScriptedGenerator(responses: [
            "[0:12] Determinant condition\n[0:01] Eigenvalue definition",
            "[1:05] Diagonalization",
            "Overview: It defines eigenvalues and ends with diagonalization.",
        ])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)

        let summary = try await summarizer.summarize(transcript, progress: nil)

        #expect(await generator.prompts.count == 3)
        #expect(summary.overview == "It defines eigenvalues and ends with diagonalization.")
        #expect(summary.keyPoints == [
            SummaryItem(text: "Eigenvalue definition", start: ms(0)),
            SummaryItem(text: "Determinant condition", start: ms(10_000)),
            SummaryItem(text: "Diagonalization", start: ms(60_000)),
        ])
    }

    @Test func promptsContainTimestampedTranscriptAndChunkPoints() async throws {
        let generator = ScriptedGenerator(responses: [
            "[0:12] Determinant condition",
            "[1:05] Diagonalization",
            "Overview.",
        ])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)

        _ = try await summarizer.summarize(transcript, progress: nil)

        let prompts = await generator.prompts
        #expect(prompts[0].contains("[0:00] eigenvalues are special\n[0:10] determinant equals zero"))
        #expect(!prompts[0].contains("diagonalize the matrix"))
        #expect(prompts[1].contains("[1:00] diagonalize the matrix"))
        // Map points are snapped (0:12 -> 0:10, 1:05 -> 1:00) before the reduce step.
        #expect(prompts[2].contains("[0:10] Determinant condition\n[1:00] Diagonalization"))
    }

    @Test func snapsInventedTimestampsIntoTheirChunk() async throws {
        let generator = ScriptedGenerator(responses: [
            "[45:00] Made-up time in chunk 1",
            "[0:03] Time from the wrong chunk",
            "Overview.",
        ])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)

        let summary = try await summarizer.summarize(transcript, progress: nil)

        #expect(summary.keyPoints.map(\.start) == [ms(10_000), ms(60_000)])
    }

    @Test func dropsDuplicatePointsAtTheSameMoment() async throws {
        let generator = ScriptedGenerator(responses: [
            "[0:01] Definition\n[0:02] Definition restated",  // both snap to 0:00
            "[1:01] Diagonalization",
            "Overview.",
        ])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)

        let summary = try await summarizer.summarize(transcript, progress: nil)

        #expect(summary.keyPoints.map(\.text) == ["Definition", "Diagonalization"])
    }

    @Test func dropsPointsThatCopyThePromptExample() async throws {
        let generator = ScriptedGenerator(responses: [
            "[0:05] \(Prompts.formatExampleText)\n[0:12] Determinant condition",
            "[1:05] Diagonalization",
            "Overview.",
        ])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)

        let summary = try await summarizer.summarize(transcript, progress: nil)

        #expect(await generator.prompts[0].contains(Prompts.formatExample))
        #expect(summary.keyPoints.map(\.text) == ["Determinant condition", "Diagonalization"])
    }

    @Test func reportsProgressForEveryStep() async throws {
        let generator = ScriptedGenerator(responses: ["[0:01] A", "[1:01] B", "O."])
        let summarizer = MapReduceSummarizer(generator: generator, configuration: configuration)
        let recorder = ProgressRecorder()

        _ = try await summarizer.summarize(transcript) { done, total in
            recorder.record(done, total)
        }

        #expect(recorder.steps == ["0/3", "1/3", "2/3", "3/3"])
    }

    @Test func emptyTranscriptMakesNoModelCalls() async throws {
        let generator = ScriptedGenerator(responses: [])
        let summary = try await MapReduceSummarizer(generator: generator).summarize([], progress: nil)

        #expect(summary == LectureSummary(overview: "", keyPoints: []))
        #expect(await generator.prompts.isEmpty)
    }

    // MARK: - Key point selection

    @Test func selectionSpreadsAcrossTheWholeLecture() {
        // 20 chunks, room for 5 points: chunks 0, 4, 9, 14, 19 (first and last included).
        let chunks = (0..<20).map { [point("chunk \($0)", at: Int64($0) * 60_000)] }

        let selected = Summarizer.selectKeyPoints(chunks, max: 5)

        #expect(selected.map(\.text) == ["chunk 0", "chunk 4", "chunk 9", "chunk 14", "chunk 19"])
    }

    @Test func selectionTakesFirstPointsBeforeSecondPoints() {
        let chunks = [
            [point("a1", at: 0), point("a2", at: 1_000)],
            [point("b1", at: 60_000), point("b2", at: 61_000)],
            [point("c1", at: 120_000)],
        ]

        #expect(Summarizer.selectKeyPoints(chunks, max: 4).map(\.text) == ["a1", "a2", "b1", "c1"])
        #expect(Summarizer.selectKeyPoints(chunks, max: 10).count == 5)
        #expect(Summarizer.selectKeyPoints([[], []], max: 3).isEmpty)
    }

    private func point(_ text: String, at milliseconds: Int64) -> SummaryItem {
        SummaryItem(text: text, start: ms(milliseconds))
    }
}

/// Returns scripted responses in order and records every prompt it receives.
actor ScriptedGenerator: TextGenerator {
    private var responses: [String]
    private(set) var prompts: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(instructions: String, prompt: String, maxTokens: Int) throws -> String {
        prompts.append(prompt)
        guard !responses.isEmpty else { throw ScriptExhausted() }
        return responses.removeFirst()
    }

    struct ScriptExhausted: Error {}
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []

    var steps: [String] { lock.withLock { _steps } }

    func record(_ done: Int, _ total: Int) {
        lock.withLock { _steps.append("\(done)/\(total)") }
    }
}
