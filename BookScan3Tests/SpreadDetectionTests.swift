import XCTest
import UIKit
import CoreImage
@testable import BookScan3

final class SpreadDetectionTests: XCTestCase {
    private func quad(_ x0: Double, _ x1: Double) -> Quad {
        Quad(points: [CGPoint(x: x0, y: 0.9), CGPoint(x: x1, y: 0.86), CGPoint(x: x1, y: 0.1), CGPoint(x: x0, y: 0.12)])
    }
    private func source() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).jpegData(withCompressionQuality: 0.95) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            UIColor.blue.setFill(); context.fill(CGRect(x: 400, y: 0, width: 400, height: 600))
        }
    }
    func testPairRequiresTwoAdjacentPagesAndRejectsNestedRectangles() throws {
        let left = BookSpreadDetector.Candidate(quad: quad(0.07, 0.5), confidence: 0.95)
        let right = BookSpreadDetector.Candidate(quad: quad(0.5, 0.94), confidence: 0.95)
        let pair = try XCTUnwrap(BookSpreadDetector.bestPair([left, right]))
        XCTAssertTrue(pair.geometry.isValid)
        // 명확히 인접한 양면 페이지를 모델링하기 위해 동일한 접힘선 끝점 좌표를 사용합니다.
        var alignedRight = right
        alignedRight.quad.points[0] = left.quad.points[1]
        alignedRight.quad.points[3] = left.quad.points[2]
        XCTAssertTrue(try XCTUnwrap(BookSpreadDetector.bestPair([left, alignedRight])).canAutoSave)
        XCTAssertNil(BookSpreadDetector.bestPair([left]))
        XCTAssertNil(BookSpreadDetector.bestPair([left, left]))
        XCTAssertNil(BookSpreadDetector.bestPair([left, .init(quad: quad(0.7, 0.98), confidence: 0.99)]))
    }
    func testInvalidGeometryCannotCropOriginal() {
        var geometry = SpreadGeometry.guide
        geometry.points[1] = CGPoint(x: 0.98, y: 0.5)
        XCTAssertFalse(geometry.isValid)
        XCTAssertThrowsError(try ImageProcessor.processSpread(source(), geometry: geometry))
        geometry.points = []
        XCTAssertFalse(geometry.isValid)
    }
    func testSeamTracksTiltAndRejectsIntermittentText() {
        let w = 192, h = 160
        var gray = [Double](repeating: 0.9, count: w * h)
        for y in 0..<h {
            let x = Int(70 + Double(y) * 0.2)
            for dx in -2...2 { gray[y * w + x + dx] = 0.1 }
        }
        let seam = BookSpreadDetector.seamEstimate(gray: gray, width: w, height: h)
        XCTAssertGreaterThan(seam.confidence, 0.8)
        XCTAssertEqual(seam.bottom, 70.0 / 191, accuracy: 0.025)
        XCTAssertEqual(seam.top, 102.0 / 191, accuracy: 0.025)
        for y in 0..<h where y % 12 < 8 {
            for x in 0..<w { gray[y * w + x] = 0.9 }
        }
        XCTAssertLessThan(BookSpreadDetector.seamEstimate(gray: gray, width: w, height: h).confidence, 0.5)
        XCTAssertEqual(BookSpreadDetector.seamEstimate(gray: [Double](repeating: 0.9, count: w * h), width: w, height: h).confidence, 0)
    }
    func testBlankPhotoCannotBeAutomaticallySplit() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let detection = try BookSpreadDetector.detect(CIImage(data: data)!)
        XCTAssertFalse(detection.canAutoSave)
        XCTAssertThrowsError(try ImageProcessor.process(data, split: true, spine: nil))
    }
    func testIndependentPageCropsKeepLeftAndRightContent() throws {
        let geometry = SpreadGeometry.from(outer: Quad(points: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)]), top: 0.5, bottom: 0.5)
        let pages = try ImageProcessor.processSpread(source(), geometry: geometry)
        XCTAssertEqual(pages.count, 2)
        for index in 0..<2 {
            let image = try XCTUnwrap(CIImage(data: pages[index]))
            var pixel = [UInt8](repeating: 0, count: 4)
            ImageProcessor.context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            XCTAssertGreaterThan(pixel[index == 0 ? 0 : 2], 220)
            XCTAssertLessThan(pixel[index == 0 ? 2 : 0], 30)
        }
    }
    func testCaptureSourceAndDraftSurviveReloadAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(root: root)
        let book = Book(title: "원본 보존")
        let data = source()
        let record = try await storage.createCapture(data: data, bookID: book.id, filter: .original, curvature: 0)
        try await storage.save([book]); try await storage.removeUnused([book])
        let restored = try await StorageManager(root: root).captures()
        XCTAssertEqual(restored, [record])
        let bytes = try await storage.source(record); XCTAssertEqual(bytes, data)
        try await storage.save([]); try await storage.removeUnused([])
        let remaining = try await storage.captures(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: record.sourceName).path))
    }
    func testLegacyPagesDecodeWithoutCaptureFields() throws {
        let page = ScanPage(imageName: "a.jpg", originalName: "b.jpg", thumbnailName: "c.jpg")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        json.removeValue(forKey: "captureID"); json.removeValue(forKey: "captureSide")
        let restored = try JSONDecoder().decode(ScanPage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.captureID); XCTAssertEqual(restored.id, page.id)
    }
    func testCaptureHintRejectsMovementAspectChangeAndStalePreview() {
        let now = Date()
        let hint = SpreadCaptureHint(geometry: .guide, aspect: 1.4, observedAt: now)
        XCTAssertTrue(hint.agrees(with: .guide, aspect: 1.4, now: now))
        XCTAssertFalse(hint.agrees(with: .guide, aspect: 0.7, now: now))
        XCTAssertFalse(hint.agrees(with: .guide, aspect: 1.4, now: now.addingTimeInterval(3)))
        var moved = SpreadGeometry.guide; moved.points[1].x += 0.1
        XCTAssertFalse(hint.agrees(with: moved, aspect: 1.4, now: now))
    }
    @MainActor
    func testReviewReplacesPagesPreservingIDsAndDeletedSibling() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryViewModel(root: root)
        await library.load(); await library.create(title: "재보정")
        let book = try XCTUnwrap(library.selected)
        let record = try await library.storage.createCapture(data: source(), bookID: book.id, filter: .original, curvature: 0)
        let saved = await library.saveReviewed(record); XCTAssertTrue(saved)
        var first = try XCTUnwrap(library.selected)
        XCTAssertEqual(first.pages.count, 2)
        let pageID = first.pages[0].id
        first.pages.removeLast(); await library.update(first)
        var adjusted = record; adjusted.geometry.points[1].x = 0.45
        let resaved = await library.saveReviewed(adjusted); XCTAssertTrue(resaved)
        XCTAssertEqual(library.selected?.pages.count, 1)
        XCTAssertEqual(library.selected?.pages.first?.id, pageID)
        XCTAssertNil(library.error)
        let reloaded = LibraryViewModel(root: root); await reloaded.load()
        XCTAssertTrue(reloaded.drafts.isEmpty)
        let raw = try await reloaded.storage.source(record); XCTAssertEqual(raw, source())
    }
}
