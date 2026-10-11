import Shared
import SwiftUI

/// One lecture: its transcript (live while transcribing, otherwise from storage)
/// and its summary, whose key points jump to the matching transcript moment.
struct LectureDetailView: View {
    enum Tab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
    }

    let lecture: Lecture
    let model: LibraryViewModel

    @State private var tab: Tab = .transcript
    @State private var storedSegments: [TranscriptSegment] = []
    @State private var loadError: String?
    /// Transcript time to scroll to after tapping a summary point.
    @State private var scrollTarget: LectureTime?

    private var isActive: Bool { model.activeLectureID == lecture.id }
    private var segments: [TranscriptSegment] { isActive ? model.liveSegments : storedSegments }

    var body: some View {
        Group {
            switch tab {
            case .transcript: transcript
            case .summary: SummaryView(lecture: lecture, model: model, canSummarize: !isActive && !segments.isEmpty) { time in
                scrollTarget = time
                tab = .transcript
            }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(lecture.title)
        // Reload when switching lectures and when this lecture's transcription ends.
        .task(id: ReloadKey(lectureID: lecture.id, isActive: isActive)) {
            guard !isActive else { return }
            do {
                storedSegments = try await model.segments(for: lecture.id)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            await model.summaries.loadSaved(for: lecture.id)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                if let stats = model.runStats[lecture.id] {
                    Section {
                        Label(stats, systemImage: "speedometer")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(segment.start.description)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .trailing)
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                        .id(segment.id)
                        .listRowBackground(isHighlighted(segment) ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
            }
            .onChange(of: scrollTarget, initial: true) {
                guard let target = segment(at: scrollTarget) else { return }
                withAnimation { proxy.scrollTo(target.id, anchor: .center) }
            }
        }
        .overlay {
            if let loadError {
                ContentUnavailableView("Couldn't Load Transcript", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if segments.isEmpty {
                if isActive {
                    ProgressView("Transcribing…")
                } else {
                    ContentUnavailableView("No Transcript", systemImage: "text.alignleft",
                                           description: Text("No speech was transcribed for this lecture."))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isActive {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Transcribing \(lecture.sourceFileName ?? lecture.title)…")
                    Spacer()
                    Button("Stop") { model.cancelTranscription() }
                }
                .padding()
                .background(.bar)
            }
        }
    }

    /// The segment containing `time` (summary points are snapped to segment starts).
    private func segment(at time: LectureTime?) -> TranscriptSegment? {
        guard let time else { return nil }
        return segments.last { $0.start <= time }
    }

    private func isHighlighted(_ segment: TranscriptSegment) -> Bool {
        self.segment(at: scrollTarget)?.id == segment.id
    }

    private struct ReloadKey: Equatable {
        let lectureID: Lecture.ID
        let isActive: Bool
    }
}

/// Overview and timestamped key points, or a button to generate them.
private struct SummaryView: View {
    let lecture: Lecture
    let model: LibraryViewModel
    let canSummarize: Bool
    let onSelectTime: (LectureTime) -> Void

    private var controller: SummaryController { model.summaries }

    var body: some View {
        let state = controller.state(for: lecture.id)
        if let summary = controller.summaries[lecture.id], !controller.isWorking(on: lecture.id) {
            List {
                if !summary.overview.isEmpty {
                    Section("Overview") {
                        Text(summary.overview)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    ForEach(summary.keyPoints, id: \.self) { point in
                        Button {
                            onSelectTime(point.start)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(point.start.description)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tint)
                                    .frame(minWidth: 44, alignment: .trailing)
                                Text(point.text)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this moment in the transcript")
                    }
                } header: {
                    Text("Key points")
                } footer: {
                    HStack {
                        Text("Generated on this device by \(SummaryController.modelName).")
                        Spacer()
                        Button("Regenerate") { Task { await controller.summarize(lecture.id) } }
                            .disabled(!canSummarize || controller.isBusy)
                    }
                    .font(.caption)
                }
            }
        } else {
            ContentUnavailableView {
                Label(title(for: state), systemImage: "sparkles")
            } description: {
                Text(description(for: state))
            } actions: {
                switch state {
                case .loadingModel(let progress):
                    ProgressView(value: progress > 0 ? progress : nil)
                        .frame(maxWidth: 240)
                case .summarizing(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(maxWidth: 240)
                case .idle, .failed:
                    Button("Summarize") { Task { await controller.summarize(lecture.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSummarize || controller.isBusy)
                }
            }
        }
    }

    private func title(for state: SummaryController.State) -> String {
        switch state {
        case .idle: "No Summary Yet"
        case .loadingModel: "Loading Language Model…"
        case .summarizing: "Summarizing…"
        case .failed: "Summary Failed"
        }
    }

    private func description(for state: SummaryController.State) -> String {
        switch state {
        case .idle:
            canSummarize
                ? "Summarize this lecture on your device. Nothing leaves your device."
                : "A summary can be made once the transcript is finished."
        case .loadingModel(let progress) where progress > 0 && progress < 1:
            "Downloading \(SummaryController.modelName) (one time, about 1 GB)… \(Int(progress * 100))%"
        case .loadingModel:
            "Loading \(SummaryController.modelName)…"
        case .summarizing(let done, let total):
            "Step \(done) of \(total)"
        case .failed(let message):
            message
        }
    }
}
