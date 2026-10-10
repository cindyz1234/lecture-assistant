import Storage
import SwiftUI

@main
struct LectureAssistantApp: App {
    @State private var model: LibraryViewModel

    init() {
        // Composition root: the only place that picks concrete implementations.
        do {
            let store = try SQLiteLectureStore(url: SQLiteLectureStore.defaultURL())
            _model = State(initialValue: LibraryViewModel(store: store))
        } catch {
            _model = State(initialValue: LibraryViewModel(
                store: InMemoryLectureStore(),
                storageWarning: "Couldn't open the lecture database, so nothing will be saved: \(error.localizedDescription)"
            ))
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
        }
    }
}
