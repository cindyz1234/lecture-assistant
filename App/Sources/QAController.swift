import Foundation
import MLXSearch
import MLXSummarization
import Observation
import Search
import Shared
import Storage

/// Q&A over lectures: keeps the passage index up to date and answers questions
/// from it with the on-device LLM.
@MainActor
@Observable
final class QAController {
    enum IndexState: Equatable {
        case idle
        case loadingModel
        case indexing(done: Int, total: Int)
        case ready(passages: Int)
        case failed(String)
    }

    enum AskState: Equatable {
        case idle
        case loadingModel(progress: Double)
        case answering
        case answered(question: String)
        case failed(String)
    }

    /// Settings chosen on the dev question set (docs/RESULTS.md).
    static let keywordWeight = 0.25

    private(set) var indexState: IndexState = .idle
    private(set) var askState: AskState = .idle
    private(set) var answer: Answer?
    /// Lecture titles by ID, for citations and the prompt.
    private(set) var lectureTitles: [Lecture.ID: String] = [:]

    private let store: any LectureStore
    private let models: ModelProvider
    /// Built from the stored index; nil when it needs rebuilding.
    private var retriever: HybridRetriever?
    private var indexingTask: Task<Void, Never>?

    init(store: any LectureStore, models: ModelProvider) {
        self.store = store
        self.models = models
    }

    var isBusy: Bool {
        switch askState {
        case .loadingModel, .answering: true
        case .idle, .answered, .failed: false
        }
    }

    // MARK: - Index

    /// Indexes every complete lecture that isn't indexed yet. Safe to call often.
    func ensureIndexed() {
        guard indexingTask == nil else { return }
        indexingTask = Task {
            defer { indexingTask = nil }
            do {
                indexState = .loadingModel
                let embedder = try await models.embedder()
                let missing = try await store.lecturesMissingPassages(model: embedder.modelID)
                for (done, lectureID) in missing.enumerated() {
                    indexState = .indexing(done: done, total: missing.count)
                    try await index(lectureID, with: embedder)
                }
                if !missing.isEmpty { retriever = nil }
                let count = try await store.embeddedPassages(model: embedder.modelID).count
                indexState = .ready(passages: count)
            } catch {
                indexState = .failed("Couldn't index lectures: \(error.localizedDescription)")
            }
        }
    }

    /// Call when a lecture finishes transcribing or is deleted.
    func lecturesChanged() {
        retriever = nil
        ensureIndexed()
    }

    private func index(_ lectureID: Lecture.ID, with embedder: MLXTextEmbedder) async throws {
        let segments = try await store.segments(for: lectureID)
        let embedded = try await PassageIndexer.embed(segments, lectureID: lectureID, embedder: embedder)
        try await store.savePassages(embedded, for: lectureID)
    }

    // MARK: - Ask

    /// Answers `question` from all lectures, or only from `lectureID` if given.
    func ask(_ question: String, in lectureID: Lecture.ID?) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        answer = nil
        do {
            askState = .loadingModel(progress: 0)
            let generator = try await models.generator { progress in
                Task { @MainActor in
                    if case .loadingModel = self.askState { self.askState = .loadingModel(progress: progress) }
                }
            }
            askState = .answering
            let retriever = try await scopedRetriever(lectureID)
            var answerer = QuestionAnswerer(retriever: retriever, generator: generator)
            answerer.lectureTitles = lectureTitles
            answer = try await answerer.answer(question)
            askState = .answered(question: question)
        } catch {
            askState = .failed("Couldn't answer: \(error.localizedDescription)")
        }
    }

    /// A retriever over all indexed passages, or only one lecture's.
    private func scopedRetriever(_ lectureID: Lecture.ID?) async throws -> HybridRetriever {
        let all = try await fullRetriever()
        return lectureID.map { all.scoped(to: $0) } ?? all
    }

    private func fullRetriever() async throws -> HybridRetriever {
        if let retriever { return retriever }
        let embedder = try await models.embedder()
        lectureTitles = Dictionary(uniqueKeysWithValues: try await store.lectures().map { ($0.id, $0.title) })
        let store = store
        var built = HybridRetriever(embedded: try await store.embeddedPassages(model: embedder.modelID), embedder: embedder) {
            query, limit in try await store.searchTranscripts(query, limit: limit, matching: .anyWord)
        }
        built.keywordWeight = Self.keywordWeight
        retriever = built
        return built
    }
}
