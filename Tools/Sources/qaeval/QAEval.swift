import ArgumentParser
import Foundation
import MLXSearch
import Search
import Shared
import Storage
import ToolSupport

/// Measures Q&A retrieval: does the right passage come back for each question?
///
/// Builds a library from every lecture's transcript (`*.segments.json` from
/// `transcribe`), so each question searches all lectures, as in the app. A
/// retrieved passage is correct if it is from the question's lecture and
/// overlaps the question's answer window by at least `--min-overlap` seconds.
@main
struct QAEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evaluate keyword, semantic and hybrid retrieval on the Q&A question set.",
        discussion: """
        MLX needs an xcodebuild build (Metal shaders):
          xcodebuild build -scheme qaeval -destination platform=macOS -configuration Release \\
            -derivedDataPath Tools/.xcbuild -skipMacroValidation -skipPackagePluginValidation -workspace Tools
          Tools/.xcbuild/Build/Products/Release/qaeval --split dev \\
            --transcripts ml/eval/outputs/base.en --transcripts ml/eval/outputs/base.en-traindev
        """
    )

    @Option(help: "Question file (JSONL).")
    var questions = "ml/eval/qa_questions.jsonl"

    @Option(help: "Which questions to score: dev, test or all.")
    var split = "dev"

    @Option(help: "Directories with <lecture_id>.segments.json; earlier ones win for duplicate lectures.")
    var transcripts: [String]

    @Option(help: "Embedding model: bge-small or minilm.")
    var model = "bge-small"

    @Option(help: "Passage length in seconds.")
    var passageSeconds = 60

    @Option(help: "Seconds between passage starts (overlap = length - stride).")
    var strideSeconds = 30

    @Option(help: "Weight of keyword search in hybrid fusion (semantic = 1).")
    var keywordWeight = 1.0

    @Option(help: "Seconds a passage must overlap the answer window to count as correct.")
    var minOverlap = 20.0

    @Option(help: "Write per-question results (JSONL) here.")
    var details: String?

    struct Question: Decodable {
        let id: String
        let split: String
        let lecture_id: String
        let question: String
        let start: Double
        let end: Double
    }

    func run() async throws {
        let allQuestions = try String(contentsOfFile: questions, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(Question.self, from: Data($0.utf8)) }
        let selected = allQuestions.filter { split == "all" || $0.split == split }
        guard !selected.isEmpty else { throw ValidationError("No questions for split \(split).") }

        // Library: every lecture with a transcript, each under a fresh ID.
        let store = try SQLiteLectureStore.inMemory()
        var lectureIDs: [String: Lecture.ID] = [:]
        var passages: [Passage] = []
        var hours = 0.0
        for directory in transcripts {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".segments.json") }.sorted()
            for file in files {
                let name = String(file.dropLast(".segments.json".count))
                guard lectureIDs[name] == nil else { continue }
                let segments = try JSONDecoder().decode([TranscriptSegment].self,
                                                        from: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(file)))
                let lecture = Lecture(title: name)
                lectureIDs[name] = lecture.id
                try await store.save(lecture)
                try await store.append(segments, to: lecture.id)
                passages += PassageBuilder.passages(segments, lectureID: lecture.id,
                                                    length: .seconds(passageSeconds), stride: .seconds(strideSeconds))
                hours += (segments.last?.end.seconds ?? 0) / 3600
            }
        }
        let missing = Set(selected.map(\.lecture_id)).subtracting(lectureIDs.keys)
        guard missing.isEmpty else { throw ValidationError("No transcript for: \(missing.sorted().joined(separator: ", "))") }
        log(String(format: "Library: %d lectures, %.1f hours, %d passages", lectureIDs.count, hours, passages.count))

        let clock = ContinuousClock()
        var started = clock.now
        let embedderModel: MLXTextEmbedder.Model = switch model {
        case "bge-small": .bgeSmall
        case "minilm": .miniLM
        default: throw ValidationError("Unknown model \(model); use bge-small or minilm.")
        }
        let embedder = try await MLXTextEmbedder.load(embedderModel)
        var retriever = try await HybridRetriever.build(passages: passages, embedder: embedder) { query, limit in
            try await store.searchTranscripts(query, limit: limit, matching: .anyWord)
        }
        retriever.keywordWeight = keywordWeight
        log(String(format: "Embedded %d passages with %@ in %.1fs", passages.count, embedder.modelID, (clock.now - started).seconds))

        print("| Mode | Questions | Recall@1 | Recall@5 | MRR@10 | Median ms/query |")
        print("|---|---:|---:|---:|---:|---:|")
        let detailLog = details.map { FileManager.default.createFile(atPath: $0, contents: nil) ? $0 : $0 }
        let detailHandle = detailLog.flatMap { FileHandle(forWritingAtPath: $0) }
        defer { try? detailHandle?.close() }
        for mode in HybridRetriever.Mode.allCases {
            var firstCorrectRanks: [Int?] = []
            var times: [Double] = []
            for question in selected {
                started = clock.now
                let results = try await retriever.retrieve(question.question, k: 10, mode: mode)
                times.append((clock.now - started).seconds * 1000)
                let lectureID = lectureIDs[question.lecture_id]!
                let rank = results.firstIndex { isCorrect($0.passage, lectureID: lectureID, question: question) }.map { $0 + 1 }
                firstCorrectRanks.append(rank)
                if let detailHandle {
                    let line: [String: Any] = ["mode": mode.rawValue, "id": question.id, "first_correct_rank": rank as Any,
                                               "top": results.prefix(5).map { "\(lectureName($0.passage.lectureID, lectureIDs)) \($0.passage.start)" }]
                    try detailHandle.write(contentsOf: JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
                }
            }
            let n = Double(selected.count)
            let recall1 = Double(firstCorrectRanks.filter { $0 == 1 }.count) / n
            let recall5 = Double(firstCorrectRanks.filter { ($0 ?? 99) <= 5 }.count) / n
            let mrr = firstCorrectRanks.reduce(0.0) { $0 + ($1.map { 1 / Double($0) } ?? 0) } / n
            times.sort()
            print(String(format: "| %@ | %d | %.2f | %.2f | %.2f | %.1f |",
                         mode.rawValue, selected.count, recall1, recall5, mrr, times[times.count / 2]))
        }
    }

    private func isCorrect(_ passage: Passage, lectureID: Lecture.ID, question: Question) -> Bool {
        guard passage.lectureID == lectureID else { return false }
        let overlap = min(passage.end.seconds, question.end) - max(passage.start.seconds, question.start)
        return overlap >= minOverlap
    }

    private func lectureName(_ id: Lecture.ID, _ ids: [String: Lecture.ID]) -> String {
        ids.first { $0.value == id }?.key ?? "?"
    }
}
