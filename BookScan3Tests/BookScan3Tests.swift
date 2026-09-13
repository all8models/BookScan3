import XCTest
import UIKit
import PDFKit
@testable import BookScan3

final class BookScan3Tests: XCTestCase {
    private func imageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            UIColor.black.setFill(); context.fill(CGRect(x: 290, y: 0, width: 10, height: 400))
            ("BookScan local document" as NSString).draw(at: CGPoint(x: 35, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
        }
    }
    func testStorageRoundTripAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StorageManager(root: root)
        let empty = try await store.load(); XCTAssertTrue(empty.isEmpty)
        var book = Book(title: "로컬 테스트")
        book.pages = try await store.savePages([imageData(), imageData()], filter: .grayscale)
        book.pages[0].text = "테스트 문장"
        try await store.save([book])
        let restored = try await store.load(); XCTAssertEqual(restored, [book])
        let pdfURL = try await store.export(book)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        XCTAssertEqual(PDFDocument(url: pdfURL)?.pageCount, 2)
        let modified = try await store.refilter(book.pages[0], filter: .blackWhite)
        XCTAssertEqual(modified.originalName, book.pages[0].originalName)
        XCTAssertTrue(modified.text.isEmpty)
        XCTAssertNotEqual(modified.imageName, book.pages[0].imageName)
        try await store.save([]); try await store.removeUnused([])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files, ["library.json"])
    }
    func testInvalidStorageDoesNotResetMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.json")
        let bad = Data("not valid json".utf8); try bad.write(to: url)
        do { _ = try await StorageManager(root: root).load(); XCTFail("Corrupt metadata must throw") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    func testSplitAndFiltersProduceImages() throws {
        let geometry = SpreadGeometry.from(outer: Quad(points: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)]), top: 0.4, bottom: 0.4)
        let pages = try ImageProcessor.processSpread(imageData(), geometry: geometry)
        XCTAssertEqual(pages.count, 2)
        let left = try XCTUnwrap(UIImage(data: pages[0])), right = try XCTUnwrap(UIImage(data: pages[1]))
        XCTAssertEqual(left.size.width / (left.size.width + right.size.width), 0.4, accuracy: 0.02)
        for filter in ScanFilter.allCases {
            XCTAssertNotNil(UIImage(data: try ImageProcessor.render(pages[0], filter: filter)))
        }
        let curved = try ImageProcessor.processSpread(imageData(), geometry: geometry, curvature: 0.5)
        XCTAssertEqual(curved.count, 2)
        XCTAssertEqual(UIImage(data: curved[0])?.size, left.size)
        XCTAssertNotEqual(curved[0], pages[0])
    }
    func testAutoCaptureRequiresStabilityAndRearmsAfterMovement() {
        let quad = Quad(points: [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.1)])
        var gate = AutoCaptureGate()
        XCTAssertFalse(gate.update(quad, sharpness: 0.1, time: 0))
        XCTAssertFalse(gate.update(quad, sharpness: 0.1, time: 0.1))
        XCTAssertTrue(gate.update(quad, sharpness: 0.1, time: 0.8))
        XCTAssertFalse(gate.update(quad, sharpness: 0.1, time: 5))
        XCTAssertFalse(gate.update(nil, sharpness: 0.1, time: 6))
        XCTAssertFalse(gate.update(quad, sharpness: 0.1, time: 7))
        XCTAssertFalse(gate.update(quad, sharpness: 0.1, time: 7.1))
        XCTAssertTrue(gate.update(quad, sharpness: 0.1, time: 8))
        gate.reset()
        for i in 0..<20 { XCTAssertFalse(gate.update(quad, sharpness: 0, time: Double(i))) }
    }
    func testTransferRejectsUnauthorizedAndUnknownPaths() {
        XCTAssertEqual(TransferRoute.parse("GET /?token=secret HTTP/1.1\r\n\r\n", token: "secret"), .landing)
        XCTAssertEqual(TransferRoute.parse("GET /download.pdf?token=secret HTTP/1.1\r\n\r\n", token: "secret"), .pdf)
        for request in ["GET /download.pdf HTTP/1.1", "GET /download.pdf?token=wrong HTTP/1.1", "POST /?token=secret HTTP/1.1", "GET /../library.json?token=secret HTTP/1.1", "GET http://elsewhere/?token=secret HTTP/1.1"] {
            XCTAssertEqual(TransferRoute.parse(request, token: "secret"), .rejected)
        }
    }
    func testStorageIndividualBookSyncAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StorageManager(root: root)
        var book = Book(title: "분할 저장 테스트")
        book.pages = try await store.savePages([imageData()], filter: .original)
        try await store.save([book])

        let bookFile = root.appending(path: "books/\(book.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookFile.path))

        let libraryFile = root.appending(path: "library.json")
        try FileManager.default.removeItem(at: libraryFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile.path))

        let recovered = try await store.load()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.title, "분할 저장 테스트")
    }
    func testTransferRouteSupportsHeadRequests() {
        XCTAssertEqual(TransferRoute.parse("HEAD /?token=secret HTTP/1.1\r\n\r\n", token: "secret"), .landing)
        XCTAssertEqual(TransferRoute.parse("HEAD /download.pdf?token=secret HTTP/1.1\r\n\r\n", token: "secret"), .pdf)
    }
}
