import SwiftUI

@main
struct BookScan3App: App {
    @StateObject private var library = LibraryViewModel(root: ProcessInfo.processInfo.arguments.contains("--uitesting") ? URL.documentsDirectory.appending(path: "UITestLibrary") : URL.documentsDirectory.appending(path: "BookScan3"))
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library).tint(Theme.accent)
                .task { await library.load() }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.16, green: 0.36, blue: 0.29)
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
}
