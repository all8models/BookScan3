import SwiftUI

@main
struct BookScan3App: App {
    @StateObject private var library = LibraryViewModel(root: ProcessInfo.processInfo.arguments.contains("--uitesting") ? URL.documentsDirectory.appending(path: "UITestLibrary\(ProcessInfo.processInfo.environment["BOOKSCAN_TEST_ID"] ?? "")") : URL.documentsDirectory.appending(path: "BookScan3"))
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library).tint(Theme.accent)
                .task {
                    await library.load()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--spread-fixture"), library.books.isEmpty {
                        await library.create(title: "양면 경계 테스트")
                        if let book = library.selected {
                            let data = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 700)).jpegData(withCompressionQuality: 0.9) { context in
                                UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
                                UIColor.white.setFill(); context.fill(CGRect(x: 65, y: 50, width: 870, height: 600))
                                UIColor.gray.setFill(); context.fill(CGRect(x: 490, y: 50, width: 18, height: 600))
                                for y in stride(from: 120, to: 600, by: 38) {
                                    ("BookScan page boundaries" as NSString).draw(at: CGPoint(x: 90, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                                    ("The right page stays intact" as NSString).draw(at: CGPoint(x: 550, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                                }
                            }
                            await library.add(data: data, to: book.id, split: true, spine: 0.5, filter: .original, forceReview: true)
                        }
                    }
                    #endif
                }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.16, green: 0.73, blue: 0.64)
    static let paper = Color(red: 1, green: 1, blue: 1)
}
