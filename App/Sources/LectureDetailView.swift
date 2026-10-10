import Shared
import SwiftUI

/// Transcript of one lecture: live while it is being transcribed, otherwise loaded from storage.
struct LectureDetailView: View {
    let lecture: Lecture
    let model: LibraryViewModel

    @State private var storedSegments: [TranscriptSegment] = []
    @State private var loadError: String?

    private var isActive: Bool { model.activeLectureID == lecture.id }
    private var segments: [TranscriptSegment] { isActive ? model.liveSegments : storedSegments }

    var body: some View {
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
                }
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
        }
    }

    private struct ReloadKey: Equatable {
        let lectureID: Lecture.ID
        let isActive: Bool
    }
}
