import Shared
import Storage
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar of saved lectures with the selected transcript as the detail.
struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    @State private var isPickingFile = false
    @State private var realTime = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedLectureID) {
                if model.isSearchActive {
                    searchResults
                } else {
                    lectureRows
                }
            }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search transcripts")
            // Debounce: search once typing pauses, not on every keystroke.
            .task(id: model.searchText) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await model.runSearch()
            }
            .overlay {
                if model.isSearchActive, model.searchResults.isEmpty, model.searchedText == model.searchText {
                    ContentUnavailableView.search(text: model.searchText)
                } else if !model.isSearchActive, model.lectures.isEmpty {
                    ContentUnavailableView("No Lectures", systemImage: "books.vertical",
                                           description: Text("Imported lectures appear here."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                ModelStatusBar(model: model)
            }
            .navigationTitle("Lectures")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Toggle("Real-time", isOn: $realTime)
                        .help("Play the file at 1× speed to simulate a live lecture")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isPickingFile = true
                    }
                    .keyboardShortcut("o")
                    .disabled(!model.canImport)
                    .help("Import a lecture audio or video file (⌘O)")
                }
            }
        } detail: {
            if let lecture = model.selectedLecture {
                LectureDetailView(lecture: lecture, model: model)
                    .id(lecture.id)  // fresh tab and scroll state per lecture
            } else {
                ContentUnavailableView {
                    Label("No Lecture Selected", systemImage: "waveform")
                } description: {
                    Text("Select a lecture, or import an audio or video file.")
                } actions: {
                    Button("Import File…") { isPickingFile = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canImport)
                }
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                model.importFile(url, realTime: realTime)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            await model.start()
        }
    }
}

extension LibraryView {
    @ViewBuilder
    var lectureRows: some View {
        ForEach(model.lectures) { lecture in
            LectureRow(lecture: lecture, isActive: lecture.id == model.activeLectureID)
                .tag(lecture.id)
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteLecture(lecture.id) }
                    }
                    .disabled(lecture.id == model.activeLectureID)
                }
        }
        .onDelete { offsets in
            let ids = offsets.map { model.lectures[$0].id }
            Task {
                for id in ids {
                    await model.deleteLecture(id)
                }
            }
        }
    }

    @ViewBuilder
    var searchResults: some View {
        Section {
            ForEach(model.searchResults) { hit in
                Button {
                    model.open(hit)
                } label: {
                    SearchResultRow(hit: hit)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the lecture at this moment")
            }
        } header: {
            if !model.searchResults.isEmpty {
                let count = model.searchResults.count
                Text(count == LibraryViewModel.searchResultLimit ? "Top \(count) results" : "\(count) results")
            }
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.lectureTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(hit.start.description)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            Text(highlighted)
                .font(.callout)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The segment text with matched words in bold.
    private var highlighted: AttributedString {
        hit.fragments.reduce(into: AttributedString()) { result, fragment in
            var piece = AttributedString(fragment.text)
            if fragment.isMatch {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            result.append(piece)
        }
    }
}

private struct LectureRow: View {
    let lecture: Lecture
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lecture.title)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(lecture.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if lecture.duration > .zero {
                    Text("· \(lecture.duration.description)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            statusLabel
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch lecture.status {
        case .transcribing where isActive:
            Label("Transcribing…", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.tint)
        case .transcribing, .interrupted:
            Label("Interrupted", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .complete:
            EmptyView()
        }
    }
}

private struct ModelStatusBar: View {
    let model: LibraryViewModel

    var body: some View {
        Group {
            if let warning = model.storageWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                switch model.modelState {
                case .loading(let progress) where progress > 0 && progress < 1:
                    VStack(alignment: .leading) {
                        Text("Downloading speech model (\(LibraryViewModel.modelName))… \(Int(progress * 100))%")
                        ProgressView(value: progress)
                    }
                case .loading:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading speech model (\(LibraryViewModel.modelName))…")
                    }
                case .ready:
                    EmptyView()
                case .failed(let message):
                    VStack(alignment: .leading) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await model.loadModel() } }
                    }
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(model.modelState == .ready && model.storageWarning == nil ? 0 : 12)
        .background(.bar)
    }
}

#Preview {
    LibraryView(model: LibraryViewModel(store: InMemoryLectureStore()))
}
