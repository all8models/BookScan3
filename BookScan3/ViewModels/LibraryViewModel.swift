import SwiftUI
import CoreImage

enum LibraryTaskState: Equatable, Sendable {
    case idle
    case busy(operation: String)
    case recognizing(current: Int, total: Int)

    var description: String {
        switch self {
        case .idle: return ""
        case .busy(let op): return op
        case .recognizing(let current, let total): return "텍스트 인식 \(current) / \(total)"
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var drafts: [CaptureRecord] = []
    @Published var progress = ""
    @Published private(set) var taskState: LibraryTaskState = .idle
    let storage: StorageServiceProtocol
    let root: URL
    private let ocr: OCRServiceProtocol
    private var searchIndexer = BookSearchIndexer()

    init(
        root: URL = URL.documentsDirectory.appending(path: "BookScan3"),
        storage: StorageServiceProtocol? = nil,
        ocr: OCRServiceProtocol? = nil
    ) {
        self.root = root
        self.storage = storage ?? StorageManager(root: root)
        self.ocr = ocr ?? OCRService()
    }
    var selected: Book? { books.first { $0.id == selectedID } }

    func search(query: String) -> [Book] {
        searchIndexer.search(query: query, in: books)
    }

    func load() async {
        guard !loaded else { return }
        do {
            books = try await storage.load()
            searchIndexer.index(books: books)
            let references = Set(books.flatMap(\.pages).compactMap(\.captureID))
            let bookIDs = Set(books.map(\.id))
            drafts = try await storage.captures().filter { $0.isPending && !references.contains($0.id) && bookIDs.contains($0.bookID) }
            loaded = true
        }
        catch { self.error = "서재를 열 수 없습니다. 기존 데이터는 보존됩니다.\n\(error.localizedDescription)" }
    }

    private func commit(_ updated: [Book]) async throws {
        try await storage.save(updated)
        books = updated
        searchIndexer.index(books: updated)
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
        do { try await commit(books.filter { $0.id != book.id }); drafts.removeAll { $0.bookID == book.id }; if selectedID == book.id { selectedID = nil }; try await storage.removeUnused(books) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func add(data: Data, to id: UUID, split: Bool, spine: Double?, filter: ScanFilter, curvature: Double = 0, forceReview: Bool = false, hint: SpreadCaptureHint? = nil) async -> CaptureRecord? {
        guard !busy, books.contains(where: { $0.id == id }) else { return nil }
        busy = true; progress = "페이지 보정 및 저장 중…"; taskState = .busy(operation: progress); defer { busy = false; progress = ""; taskState = .idle }
        do {
            if split {
                var record = try await storage.createCapture(data: data, bookID: id, filter: filter, curvature: curvature)
                drafts.append(record)
                let detection = try await Task.detached(priority: .userInitiated) {
                    guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ScanError.message("이미지를 읽을 수 없습니다.") }
                    var result = try BookSpreadDetector.detect(image, manualSpine: spine)
                    if let hint, !hint.agrees(with: result.geometry, aspect: image.extent.width / image.extent.height) {
                        result.confidence = min(result.confidence, 0.5)
                        result.reason = "촬영 전후 경계가 달라졌어요. 원본에서 위치를 확인해 주세요."
                    }
                    return result
                }.value
                record.geometry = detection.geometry; record.note = detection.reason
                try await storage.saveCapture(record)
                if let index = drafts.firstIndex(where: { $0.id == record.id }) { drafts[index] = record }
                guard detection.canAutoSave, !forceReview else { return record }
                try await saveCapturePages(record)
                return nil
            }
            let images = try await Task.detached(priority: .userInitiated) { try ImageProcessor.process(data, split: split, spine: spine, curvature: curvature) }.value
            let pages = try await storage.savePages(images, filter: filter)
            guard var book = books.first(where: { $0.id == id }) else { return nil }
            book.pages += pages
            try await replace(book)
        } catch { self.error = error.localizedDescription }
        return nil
    }

    func saveReviewed(_ record: CaptureRecord) async -> Bool {
        guard !busy else { return false }
        busy = true; progress = "원본에서 좌우 페이지 보정 중…"; taskState = .busy(operation: progress); defer { busy = false; progress = ""; taskState = .idle }
        do { try await saveCapturePages(record); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    private func saveCapturePages(_ record: CaptureRecord) async throws {
        guard record.geometry.isValid else { throw ScanError.message("바깥 모서리와 접힘선의 위치를 다시 확인해 주세요.") }
        guard var book = books.first(where: { $0.id == record.bookID }) else { throw ScanError.message("책을 찾을 수 없습니다.") }
        let source = try await storage.source(record)
        let images = try await Task.detached(priority: .userInitiated) {
            try ImageProcessor.processSpread(source, geometry: record.geometry, curvature: record.curvature)
        }.value
        var pages = try await storage.savePages(images, filter: record.filter)
        for index in pages.indices { pages[index].captureID = record.id; pages[index].captureSide = index }
        if book.pages.contains(where: { $0.captureID == record.id }) {
            // 페이지 순서와 ID를 유지하며, 사용자가 명시적으로 삭제한 형제 페이지는 다시 생성하지 않습니다.
            for index in book.pages.indices where book.pages[index].captureID == record.id {
                guard let side = book.pages[index].captureSide, pages.indices.contains(side) else { throw ScanError.message("페이지 연결 정보가 올바르지 않습니다.") }
                var page = pages[side]
                if page.filter != book.pages[index].filter { page = try await storage.refilter(page, filter: book.pages[index].filter) }
                page.id = book.pages[index].id; page.createdAt = book.pages[index].createdAt
                book.pages[index] = page
            }
        } else { book.pages += pages }
        try await storage.saveCapture(record)
        try await replace(book)
        var completed = record; completed.isPending = false
        // 라이브러리 메타데이터 저장이 최종 확정(Commit) 기준입니다. 이 완료 마커 저장이 실패하더라도,
        // 앱 재실행 시 페이지 참조 정보를 통해 캡처를 온전히 복원할 수 있습니다.
        try? await storage.saveCapture(completed)
        drafts.removeAll { $0.id == record.id }
        try? await storage.removeUnused(books)
    }

    func discardDraft(_ record: CaptureRecord) async {
        guard !busy, !books.flatMap(\.pages).contains(where: { $0.captureID == record.id }) else { return }
        busy = true; defer { busy = false }
        do { try await storage.deleteCapture(record); drafts.removeAll { $0.id == record.id } }
        catch { self.error = error.localizedDescription }
    }
    func deletePages(_ ids: Set<UUID>, bookID: UUID) async {
        guard !busy, var book = books.first(where: { $0.id == bookID }) else { return }
        busy = true; defer { busy = false }
        do {
            book.pages.removeAll { ids.contains($0.id) }
            try await replace(book)
            try await storage.removeUnused(books)
        } catch { self.error = error.localizedDescription }
    }

    func recognize(bookID: UUID, pageID: UUID? = nil) async {
        guard !busy, var book = books.first(where: { $0.id == bookID }) else { return }
        busy = true; defer { busy = false; progress = ""; taskState = .idle }
        do {
            let indices = book.pages.indices.filter { pageID == nil || book.pages[$0].id == pageID }
            for (offset, index) in indices.enumerated() {
                taskState = .recognizing(current: offset + 1, total: indices.count)
                progress = taskState.description
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
        busy = true; progress = "PDF 만드는 중…"; taskState = .busy(operation: progress); defer { busy = false; progress = ""; taskState = .idle }
        do { return try await storage.export(book) } catch { self.error = error.localizedDescription; return nil }
    }
    func capture(_ id: UUID) async throws -> CaptureRecord {
        try await storage.capture(id)
    }
    func source(_ record: CaptureRecord) async throws -> Data {
        try await storage.source(record)
    }
    func cleanupUnusedFiles() async {
        try? await storage.removeUnused(books)
    }
}
