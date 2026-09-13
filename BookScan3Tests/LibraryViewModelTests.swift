import XCTest
import CoreGraphics
@testable import BookScan3

actor MockStorageManager: StorageServiceProtocol {
    nonisolated let root: URL = URL(fileURLWithPath: "/mock/root")
    var books: [Book] = []
    var captureRecords: [UUID: CaptureRecord] = [:]
    var sourceData: [String: Data] = [:]
    var pageBytes: [String: Data] = [:]
    var removeUnusedCallCount = 0
    var exportURL: URL?

    func load() async throws -> [Book] {
        return books
    }

    func save(_ books: [Book]) async throws {
        self.books = books
    }

    func savePages(_ images: [Data], filter: ScanFilter) async throws -> [ScanPage] {
        return images.map { data in
            let id = UUID().uuidString
            let name = "\(id).jpg", original = "\(id)-original.jpg", thumb = "\(id)-thumb.jpg"
            pageBytes[name] = data
            pageBytes[original] = data
            pageBytes[thumb] = data
            return ScanPage(imageName: name, originalName: original, thumbnailName: thumb, filter: filter)
        }
    }

    func refilter(_ page: ScanPage, filter: ScanFilter) async throws -> ScanPage {
        var updated = page
        updated.filter = filter
        return updated
    }

    func data(for page: ScanPage) async throws -> Data {
        return pageBytes[page.imageName] ?? Data()
    }

    func createCapture(data: Data, bookID: UUID, filter: ScanFilter, curvature: Double) async throws -> CaptureRecord {
        let record = CaptureRecord(bookID: bookID, sourceName: "\(UUID().uuidString).source", filter: filter, curvature: curvature)
        captureRecords[record.id] = record
        sourceData[record.sourceName] = data
        return record
    }

    func saveCapture(_ record: CaptureRecord) async throws {
        captureRecords[record.id] = record
    }

    func capture(_ id: UUID) async throws -> CaptureRecord {
        guard let record = captureRecords[id] else {
            throw ScanError.message("캡처를 찾을 수 없습니다.")
        }
        return record
    }

    func source(_ record: CaptureRecord) async throws -> Data {
        return sourceData[record.sourceName] ?? Data()
    }

    func captures() async throws -> [CaptureRecord] {
        return Array(captureRecords.values)
    }

    func deleteCapture(_ record: CaptureRecord) async throws {
        captureRecords.removeValue(forKey: record.id)
        sourceData.removeValue(forKey: record.sourceName)
    }

    func removeUnused(_ books: [Book]) async throws {
        removeUnusedCallCount += 1
    }

    func export(_ book: Book) async throws -> URL {
        guard !book.pages.isEmpty else { throw ScanError.message("페이지가 없습니다.") }
        return exportURL ?? URL(fileURLWithPath: "/tmp/mock-export.pdf")
    }
}

actor MockOCRService: OCRServiceProtocol {
    var recognizedText: String = "모의 OCR 인식 결과"
    func recognize(_ data: Data) async throws -> String {
        return recognizedText
    }
}

@MainActor
final class LibraryViewModelTests: XCTestCase {

    func testLoadInitializesBooksAndDrafts() async throws {
        let mockStorage = MockStorageManager()
        let bookID = UUID()
        let existingBook = Book(id: bookID, title: "기존 도서")
        try await mockStorage.save([existingBook])

        var draft = CaptureRecord(bookID: bookID, sourceName: "test.source", filter: .original, curvature: 0)
        draft.isPending = true
        try await mockStorage.saveCapture(draft)

        let vm = LibraryViewModel(storage: mockStorage)
        XCTAssertFalse(vm.loaded)

        await vm.load()

        XCTAssertTrue(vm.loaded)
        XCTAssertEqual(vm.books.count, 1)
        XCTAssertEqual(vm.books.first?.title, "기존 도서")
        XCTAssertEqual(vm.drafts.count, 1)
        XCTAssertEqual(vm.drafts.first?.id, draft.id)
    }

    func testCreateBookAddsAndSelectsBook() async {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        await vm.load()

        await vm.create(title: "테스트 도서")

        XCTAssertEqual(vm.books.count, 1)
        XCTAssertEqual(vm.books.first?.title, "테스트 도서")
        XCTAssertEqual(vm.selectedID, vm.books.first?.id)
        XCTAssertEqual(vm.selected?.title, "테스트 도서")
    }

    func testCreateBookWithEmptyTitleFallsBackToDefault() async {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        await vm.load()

        await vm.create(title: "   ")

        XCTAssertEqual(vm.books.first?.title, "새로운 책")
    }

    func testUpdateBookModifiesProperties() async {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        await vm.load()
        await vm.create(title: "이전 제목")

        guard var book = vm.books.first else {
            XCTFail("책이 생성되어야 합니다.")
            return
        }

        book.title = "변경된 제목"
        await vm.update(book)

        XCTAssertEqual(vm.books.first?.title, "변경된 제목")
    }

    func testDeleteBookRemovesBookAndCleansDrafts() async {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        await vm.load()
        await vm.create(title: "삭제할 책")

        guard let book = vm.books.first else {
            XCTFail("책이 생성되어야 합니다.")
            return
        }

        await vm.delete(book)

        XCTAssertTrue(vm.books.isEmpty)
        XCTAssertNil(vm.selectedID)
        let callCount = await mockStorage.removeUnusedCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDeletePagesRemovesPagesFromBook() async {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        await vm.load()
        await vm.create(title: "페이지 도서")

        guard var book = vm.books.first else {
            XCTFail("책이 생성되어야 합니다.")
            return
        }

        let page1 = ScanPage(imageName: "1.jpg", originalName: "1-o.jpg", thumbnailName: "1-t.jpg")
        let page2 = ScanPage(imageName: "2.jpg", originalName: "2-o.jpg", thumbnailName: "2-t.jpg")
        book.pages = [page1, page2]
        await vm.update(book)

        XCTAssertEqual(vm.books.first?.pages.count, 2)

        await vm.deletePages([page1.id], bookID: book.id)

        XCTAssertEqual(vm.books.first?.pages.count, 1)
        XCTAssertEqual(vm.books.first?.pages.first?.id, page2.id)
    }

    func testEncapsulatedCaptureAndSourceDelegation() async throws {
        let mockStorage = MockStorageManager()
        let vm = LibraryViewModel(storage: mockStorage)
        let sampleData = Data([0x01, 0x02, 0x03])
        let record = try await mockStorage.createCapture(data: sampleData, bookID: UUID(), filter: .original, curvature: 0)

        let fetchedRecord = try await vm.capture(record.id)
        XCTAssertEqual(fetchedRecord.id, record.id)

        let fetchedSource = try await vm.source(record)
        XCTAssertEqual(fetchedSource, sampleData)

        await vm.cleanupUnusedFiles()
        let callCount = await mockStorage.removeUnusedCallCount
        XCTAssertEqual(callCount, 1)
    }
}
