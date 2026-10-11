import Foundation
import MLXSummarization
import Observation
import Shared
import Storage
import Summarization

/// Generates, saves and caches lecture summaries with the on-device LLM.
///
/// The LLM (~1 GB) is loaded the first time a summary is requested, not at
/// launch, and one summary is generated at a time.
@MainActor
@Observable
final class SummaryController {
    enum State: Equatable {
        case idle
        case loadingModel(progress: Double)
        case summarizing(done: Int, total: Int)
        case failed(String)
    }

    static let modelName = ModelProvider.generatorName

    private(set) var states: [Lecture.ID: State] = [:]
    private(set) var summaries: [Lecture.ID: LectureSummary] = [:]

    private let store: any LectureStore
    private let models: ModelProvider

    init(store: any LectureStore, models: ModelProvider) {
        self.store = store
        self.models = models
    }

    func state(for lectureID: Lecture.ID) -> State {
        states[lectureID] ?? .idle
    }

    /// Whether this lecture's summary is being generated right now.
    func isWorking(on lectureID: Lecture.ID) -> Bool {
        switch state(for: lectureID) {
        case .loadingModel, .summarizing: true
        case .idle, .failed: false
        }
    }

    /// Whether any lecture is being summarized right now.
    var isBusy: Bool {
        states.keys.contains { isWorking(on: $0) }
    }

    /// Loads a saved summary into the cache, if there is one.
    func loadSaved(for lectureID: Lecture.ID) async {
        guard summaries[lectureID] == nil else { return }
        summaries[lectureID] = try? await store.summary(for: lectureID)
    }

    func summarize(_ lectureID: Lecture.ID) async {
        guard !isBusy else { return }
        do {
            let segments = try await store.segments(for: lectureID)
            let generator = try await loadGenerator(for: lectureID)
            states[lectureID] = .summarizing(done: 0, total: 1)

            let summary = try await MapReduceSummarizer(generator: generator).summarize(segments) { done, total in
                Task { @MainActor in
                    self.states[lectureID] = .summarizing(done: done, total: total)
                }
            }
            try await store.saveSummary(summary, for: lectureID)
            summaries[lectureID] = summary
            states[lectureID] = .idle
        } catch {
            states[lectureID] = .failed("Couldn't summarize: \(error.localizedDescription)")
        }
    }

    /// Drops cached state for a deleted lecture.
    func forget(_ lectureID: Lecture.ID) {
        states[lectureID] = nil
        summaries[lectureID] = nil
    }

    private func loadGenerator(for lectureID: Lecture.ID) async throws -> MLXTextGenerator {
        states[lectureID] = .loadingModel(progress: 0)
        return try await models.generator { progress in
            Task { @MainActor in
                if case .loadingModel = self.states[lectureID] {
                    self.states[lectureID] = .loadingModel(progress: progress)
                }
            }
        }
    }
}
