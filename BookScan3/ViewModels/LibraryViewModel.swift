import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var progress = ""
    let storage: StorageManager
    let root: URL
    private let ocr = OCRService()

    init(root: URL = URL.documentsDirectory.appending(path: "BookScan3")) {
        self.root = root; storage = StorageManager(root: root)
    }
    var selected: Book? { books.first { $0.id == selectedID } }
    func load() async {
        guard !loaded else { return }
        do { books = try await storage.load(); loaded = true }
        catch { self.error = "서재를 열 수 없습니다. 기존 데이터는 보존됩니다.\n\(error.localizedDescription)" }
    }

    private func commit(_ updated: [Book]) async throws {
        try await storage.save(updated)
        books = updated
    }
    func create(title: String) async {
        guard loaded, !busy else { return }
        busy = true; defer { busy = false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(title: title.isEmpty ? "새로운 책" : title)
        do { try await commit([book] + books); selectedID = book.id }
        catch { self.error = error.localizedDescription }
    }
    func update(_ book: Book) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await replace(book) } catch { self.error = error.localizedDescription }
    }
    private func replace(_ book: Book) async throws {
        var next = books
        guard let index = next.firstIndex(where: { $0.id == book.id }) else { throw ScanError.message("책을 찾을 수 없습니다.") }
        var updated = book; updated.updatedAt = Date(); next[index] = updated
        try await commit(next)
    }
    func delete(_ book: Book) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await commit(books.filter { $0.id != book.id }); if selectedID == book.id { selectedID = nil }; try await storage.removeUnused(books) }
        catch { self.error = error.localizedDescription }
    }
    func add(data: Data, to id: UUID, split: Bool, spine: Double?, filter: ScanFilter, curvature: Double = 0) async {
        guard !busy else { return }
        busy = true; progress = "페이지 보정 및 저장 중…"; defer { busy = false; progress = "" }
        do {
            let images = try await Task.detached(priority: .userInitiated) { try ImageProcessor.process(data, split: split, spine: spine, curvature: curvature) }.value
            let pages = try await storage.savePages(images, filter: filter)
            guard var book = books.first(where: { $0.id == id }) else { return }
            book.pages += pages
            try await replace(book)
        } catch { self.error = error.localizedDescription }
    }
    func recognize(bookID: UUID, pageID: UUID? = nil) async {
        guard !busy, var book = books.first(where: { $0.id == bookID }) else { return }
        busy = true; defer { busy = false; progress = "" }
        do {
            let indices = book.pages.indices.filter { pageID == nil || book.pages[$0].id == pageID }
            for (offset, index) in indices.enumerated() {
                progress = "텍스트 인식 \(offset + 1) / \(indices.count)"
                book.pages[index].text = try await ocr.recognize(storage.data(for: book.pages[index]))
                try await replace(book)
            }
        } catch { self.error = error.localizedDescription }
    }
    func apply(filter: ScanFilter, pageID: UUID, bookID: UUID) async {
        guard !busy, var book = books.first(where: { $0.id == bookID }), let index = book.pages.firstIndex(where: { $0.id == pageID }) else { return }
        busy = true; defer { busy = false }
        do { book.pages[index] = try await storage.refilter(book.pages[index], filter: filter); try await replace(book); try await storage.removeUnused(books) }
        catch { self.error = error.localizedDescription }
    }
    func export(_ book: Book) async -> URL? {
        guard !busy else { return nil }
        busy = true; progress = "PDF 만드는 중…"; defer { busy = false; progress = "" }
        do { return try await storage.export(book) } catch { self.error = error.localizedDescription; return nil }
    }
}
