import XCTest
import CoreImage
@testable import BookScan3

final class AIEngineTests: XCTestCase {

    func testCompositeDewarpEnginePassThroughWhenStrengthZero() throws {
        let engine = CompositeDewarpEngine.shared
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 300))
        let output = try engine.dewarp(input, strength: 0.0, bindingOnLeft: false)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testCompositeDewarpEngineFallbackTier2Execution() throws {
        let engine = CompositeDewarpEngine.shared
        let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        
        // 오른쪽 페이지 (제본선이 왼쪽에 위치)
        let outputRight = try engine.dewarp(input, strength: 0.15, bindingOnLeft: true)
        XCTAssertGreaterThan(outputRight.extent.width, 0)
        XCTAssertGreaterThan(outputRight.extent.height, 0)

        // 왼쪽 페이지 (제본선이 오른쪽에 위치)
        let outputLeft = try engine.dewarp(input, strength: 0.15, bindingOnLeft: false)
        XCTAssertGreaterThan(outputLeft.extent.width, 0)
        XCTAssertGreaterThan(outputLeft.extent.height, 0)
    }

    func testFingerRemovalServiceExecution() async throws {
        let service = FingerRemovalService.shared
        let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 150, height: 150))
        let output = try await service.removeOcclusions(from: input)
        XCTAssertGreaterThan(output.extent.width, 0)
        XCTAssertGreaterThan(output.extent.height, 0)
    }

    func testBookSearchIndexerBasicAndPageTextMatching() {
        var indexer = BookSearchIndexer()
        
        var bookA = Book(title: "Swift Concurrency Guide")
        bookA.pages = [
            ScanPage(imageName: "p1.jpg", originalName: "p1-orig.jpg", thumbnailName: "p1-th.jpg", text: "Actors and asynchronous tasks in modern Swift")
        ]
        
        var bookB = Book(title: "Core Image Shaders")
        bookB.pages = [
            ScanPage(imageName: "p2.jpg", originalName: "p2-orig.jpg", thumbnailName: "p2-th.jpg", text: "Metal kernel rendering and warp processing")
        ]
        
        let bookC = Book(title: "Clean Architecture Manual")
        
        let allBooks = [bookA, bookB, bookC]
        indexer.index(books: allBooks)

        // 도서 제목 토큰 검색
        let titleResults = indexer.search(query: "concurrency", in: allBooks)
        XCTAssertEqual(titleResults.map(\.id), [bookA.id])

        // OCR 페이지 본문 텍스트 토큰 검색
        let textResults = indexer.search(query: "metal", in: allBooks)
        XCTAssertEqual(textResults.map(\.id), [bookB.id])

        // 다른 도서 제목 매칭 검색
        let manualResults = indexer.search(query: "clean", in: allBooks)
        XCTAssertEqual(manualResults.map(\.id), [bookC.id])

        // 공백 쿼리 시 전체 도서 반환
        let emptyResults = indexer.search(query: "   ", in: allBooks)
        XCTAssertEqual(emptyResults.count, 3)

        // 일치하는 항목이 없을 때 빈 배열 반환
        let nonMatching = indexer.search(query: "NonexistentKeyword123", in: allBooks)
        XCTAssertTrue(nonMatching.isEmpty)
    }

    func testBookSearchIndexerIncrementalIndexing() {
        var indexer = BookSearchIndexer()
        
        let bookA = Book(title: "First Book")
        let bookB = Book(title: "Second Volume")
        
        indexer.index(book: bookA)
        XCTAssertEqual(indexer.search(query: "first", in: [bookA, bookB]).count, 1)
        XCTAssertEqual(indexer.search(query: "volume", in: [bookA, bookB]).count, 0)

        indexer.index(book: bookB)
        XCTAssertEqual(indexer.search(query: "volume", in: [bookA, bookB]).count, 1)
    }

    @MainActor
    func testLibraryViewModelSearchIntegration() async {
        let mockStorage = MockStorageManager()
        let book1 = Book(title: "iOS Development Book")
        let book2 = Book(title: "Android Kotlin Book")
        try? await mockStorage.save([book1, book2])

        let viewModel = LibraryViewModel(storage: mockStorage)
        await viewModel.load()

        let searchResults = viewModel.search(query: "Kotlin")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.id, book2.id)

        let allResults = viewModel.search(query: "")
        XCTAssertEqual(allResults.count, 2)
    }
}
