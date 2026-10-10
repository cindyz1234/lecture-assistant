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
            .overlay {
                if model.lectures.isEmpty {
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
