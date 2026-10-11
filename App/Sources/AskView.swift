import Search
import Shared
import SwiftUI

/// Ask a question about your lectures; the answer cites the moments it came from.
struct AskView: View {
    let model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var onlySelectedLecture = false

    private var qa: QAController { model.qa }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. How do you find the eigenvalues of a matrix?", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(ask)
                    if let lecture = model.selectedLecture {
                        Toggle("Only “\(lecture.title)”", isOn: $onlySelectedLecture)
                    }
                    Button(action: ask) {
                        Label("Ask", systemImage: "sparkles")
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || qa.isBusy)
                } footer: {
                    indexStatus
                }

                switch qa.askState {
                case .idle:
                    EmptyView()
                case .loadingModel(let progress):
                    Section {
                        ProgressView(value: progress > 0 ? progress : nil) {
                            Text(progress > 0 && progress < 1
                                 ? "Downloading language model (one time, about 1 GB)… \(Int(progress * 100))%"
                                 : "Loading language model…")
                        }
                    }
                case .answering:
                    Section { ProgressView("Searching your lectures and writing an answer…") }
                case .failed(let message):
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                case .answered:
                    if let answer = qa.answer {
                        AnswerSections(answer: answer, titles: qa.lectureTitles) { lectureID, time in
                            model.open(lectureID, at: time)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ask Your Lectures")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { qa.ensureIndexed() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var indexStatus: some View {
        switch qa.indexState {
        case .idle, .ready:
            Text("Answers come only from your lectures, on this device. They can be wrong: check the sources.")
        case .loadingModel:
            Text("Preparing search…")
        case .indexing(let done, let total):
            Text("Indexing lectures for questions… \(done) of \(total)")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func ask() {
        let lectureID = onlySelectedLecture ? model.selectedLectureID : nil
        Task { await qa.ask(question, in: lectureID) }
    }
}

/// The answer with tappable [n] citations, and the passages it was based on.
private struct AnswerSections: View {
    let answer: Answer
    let titles: [Lecture.ID: String]
    let open: (Lecture.ID, LectureTime) -> Void

    var body: some View {
        if answer.isAnswered {
            Section("Answer") {
                Text(linkedText)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let number = Int(url.lastPathComponent),
                              let citation = answer.citations.first(where: { $0.number == number })
                        else { return .discarded }
                        open(citation.lectureID, citation.time)
                        return .handled
                    })
                if answer.citations.isEmpty {
                    Label("This answer doesn't cite a source. Check it against your lectures.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Section {
                Label("Your lectures don't seem to cover this.", systemImage: "questionmark.circle")
            }
        }

        Section(answer.isAnswered ? "Sources" : "Closest passages") {
            ForEach(Array(answer.passages.enumerated()), id: \.element.passage.id) { index, retrieved in
                let passage = retrieved.passage
                Button {
                    open(passage.lectureID, passage.start)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("[\(index + 1)]").monospacedDigit().foregroundStyle(.tint)
                            Text(titles[passage.lectureID] ?? "Lecture").fontWeight(.semibold)
                            Spacer()
                            Text(passage.start.description).monospacedDigit().foregroundStyle(.tint)
                        }
                        .font(.caption)
                        Text(passage.text).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the lecture at this moment")
            }
        }
    }

    /// The answer with each "[n]" turned into a link to its cited moment.
    private var linkedText: AttributedString {
        var result = AttributedString()
        var remaining = answer.text[...]
        while let match = remaining.firstMatch(of: /\[(\d+)\]/) {
            result += AttributedString(remaining[..<match.range.lowerBound])
            var marker = AttributedString(String(match.0))
            marker.link = URL(string: "lectureassistant://citation/\(match.1)")
            marker.inlinePresentationIntent = .stronglyEmphasized
            result += marker
            remaining = remaining[match.range.upperBound...]
        }
        result += AttributedString(remaining)
        return result
    }
}
