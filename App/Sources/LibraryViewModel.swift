import AudioCapture
import Foundation
import Observation
import Shared
import Storage
import Transcription
import WhisperKitTranscription

/// App state: saved lectures, the speech model, and the transcription in progress.
@MainActor
@Observable
final class LibraryViewModel {
    enum ModelState: Equatable {
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    /// Whisper variant from `argmaxinc/whisperkit-coreml`.
    static let modelName = "base.en"

    private(set) var lectures: [Lecture] = []
    var selectedLectureID: Lecture.ID?
    private(set) var modelState: ModelState = .loading(progress: 0)
    /// Lecture currently being transcribed, and its segments so far.
    private(set) var activeLectureID: Lecture.ID?
    private(set) var liveSegments: [TranscriptSegment] = []
    /// Speed of each transcription run this session, e.g. "5:00 of audio in 0:42 · RTF 0.14".
    private(set) var runStats: [Lecture.ID: String] = [:]
    var errorMessage: String?

    /// Search field text; results are for the last completed search.
    var searchText = ""
    private(set) var searchResults: [SearchHit] = []
    /// The text `searchResults` belong to (lags `searchText` while typing).
    private(set) var searchedText = ""
    /// A request to show a moment in a lecture's transcript, e.g. from a search result.
    var jumpRequest: JumpRequest?

    struct JumpRequest: Equatable {
        let lectureID: Lecture.ID
        let time: LectureTime
    }

    let store: any LectureStore
    let storageWarning: String?
    let summaries: SummaryController
    let qa: QAController
    private var transcriber: WhisperKitWindowTranscriber?
    private var transcriptionTask: Task<Void, Never>?

    init(store: any LectureStore, storageWarning: String? = nil) {
        self.store = store
        self.storageWarning = storageWarning
        let models = ModelProvider()
        self.summaries = SummaryController(store: store, models: models)
        self.qa = QAController(store: store, models: models)
    }

    var canImport: Bool {
        modelState == .ready && activeLectureID == nil
    }

    var selectedLecture: Lecture? {
        lectures.first { $0.id == selectedLectureID }
    }

    // MARK: - Startup

    func start() async {
        await loadLectures()
        await recoverInterruptedLectures()
        await loadModel()
    }

    func loadModel() async {
        guard transcriber == nil else { return }
        modelState = .loading(progress: 0)
        do {
            transcriber = try await WhisperKitWindowTranscriber.load(model: Self.modelName) { progress in
                Task { @MainActor in
                    if case .loading = self.modelState {
                        self.modelState = .loading(progress: progress)
                    }
                }
            }
            modelState = .ready
        } catch {
            modelState = .failed("Couldn't load speech model: \(error.localizedDescription)")
        }
    }

    private func loadLectures() async {
        do {
            lectures = try await store.lectures()
        } catch {
            errorMessage = "Couldn't load lectures: \(error.localizedDescription)"
        }
    }

    /// Nothing is transcribing at launch, so any lecture still marked as
    /// transcribing was cut off when the app last quit or crashed.
    private func recoverInterruptedLectures() async {
        for var lecture in lectures where lecture.status == .transcribing {
            lecture.status = .interrupted
            await save(lecture)
        }
    }

    // MARK: - Transcription

    func importFile(_ pickedURL: URL, realTime: Bool) {
        guard canImport, let transcriber else { return }

        let localURL: URL
        do {
            localURL = try Self.copyIntoContainer(pickedURL)
        } catch {
            errorMessage = "Couldn't import \(pickedURL.lastPathComponent): \(error.localizedDescription)"
            return
        }

        var lecture = Lecture(
            title: pickedURL.deletingPathExtension().lastPathComponent,
            status: .transcribing,
            sourceFileName: pickedURL.lastPathComponent
        )
        lectures.insert(lecture, at: 0)
        selectedLectureID = lecture.id
        activeLectureID = lecture.id
        liveSegments = []

        let source = FileAudioSource(url: localURL, pacing: realTime ? .realTime : .asFastAsPossible)
        // Shorter windows show captions sooner when simulating a live lecture.
        let engine = WindowedTranscriptionEngine(
            transcriber: transcriber,
            windowDuration: realTime ? .seconds(10) : .seconds(30)
        )

        transcriptionTask = Task {
            defer {
                activeLectureID = nil
                try? FileManager.default.removeItem(at: localURL)
            }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try await store.save(lecture)
                for try await segment in engine.transcribe(source.chunks()) {
                    liveSegments.append(segment)
                    // Save as we go so a crash keeps everything transcribed so far.
                    try await store.append([segment], to: lecture.id)
                }
                let audioDuration = try? await source.duration()
                lecture.duration = audioDuration ?? liveSegments.last?.end ?? .zero
                lecture.status = .complete
                if !realTime, let audioDuration {
                    runStats[lecture.id] = Self.stats(audio: audioDuration, elapsed: clock.now - started)
                }
            } catch is CancellationError {
                lecture.duration = liveSegments.last?.end ?? .zero
                lecture.status = .interrupted
            } catch {
                lecture.duration = liveSegments.last?.end ?? .zero
                lecture.status = .failed
                errorMessage = "Transcription failed: \(error.localizedDescription)"
            }
            await save(lecture)
            if lecture.status == .complete {
                qa.lecturesChanged()  // index the new transcript for Q&A
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    // MARK: - Search

    static let searchResultLimit = 50

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Searches all transcripts for the current `searchText`.
    func runSearch() async {
        let text = searchText
        guard isSearchActive else {
            searchResults = []
            searchedText = text
            return
        }
        do {
            searchResults = try await store.searchTranscripts(text, limit: Self.searchResultLimit)
        } catch {
            searchResults = []
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
        searchedText = text
    }

    /// Opens the lecture containing `hit` at the matching moment.
    func open(_ hit: SearchHit) {
        open(hit.lectureID, at: hit.start)
    }

    /// Opens a lecture's transcript at `time`, e.g. from a Q&A citation.
    func open(_ lectureID: Lecture.ID, at time: LectureTime) {
        selectedLectureID = lectureID
        jumpRequest = JumpRequest(lectureID: lectureID, time: time)
    }

    // MARK: - Lectures

    func segments(for lectureID: Lecture.ID) async throws -> [TranscriptSegment] {
        try await store.segments(for: lectureID)
    }

    func deleteLecture(_ lectureID: Lecture.ID) async {
        guard lectureID != activeLectureID, !summaries.isWorking(on: lectureID) else { return }
        do {
            try await store.deleteLecture(lectureID)
            lectures.removeAll { $0.id == lectureID }
            searchResults.removeAll { $0.lectureID == lectureID }
            summaries.forget(lectureID)
            qa.lecturesChanged()  // its passages were deleted with it
            if selectedLectureID == lectureID {
                selectedLectureID = nil
            }
        } catch {
            errorMessage = "Couldn't delete lecture: \(error.localizedDescription)"
        }
    }

    /// Saves the lecture and mirrors the change in `lectures`.
    private func save(_ lecture: Lecture) async {
        do {
            try await store.save(lecture)
            if let index = lectures.firstIndex(where: { $0.id == lecture.id }) {
                lectures[index] = lecture
            }
        } catch {
            errorMessage = "Couldn't save lecture: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// RTF (real-time factor) = processing time / audio length.
    private static func stats(audio: LectureTime, elapsed: Duration) -> String? {
        guard audio.milliseconds > 0 else { return nil }
        let elapsedMs = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let rtf = Double(elapsedMs) / Double(audio.milliseconds)
        let summary = "\(audio) of audio in \(LectureTime(milliseconds: elapsedMs)) · RTF \(rtf.formatted(.number.precision(.fractionLength(2))))"
        print("[Transcription] \(modelName): \(summary)")
        return summary
    }

    /// Files from the picker are security-scoped and may disappear, so work on a copy.
    private static func copyIntoContainer(_ url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
