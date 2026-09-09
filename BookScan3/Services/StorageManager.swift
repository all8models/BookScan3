import Foundation
import UIKit
import ImageIO

actor StorageManager {
    let root: URL
    init(root: URL = URL.documentsDirectory.appending(path: "BookScan3")) {
        self.root = root
    }

    func load() throws -> [Book] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
    }

    func save(_ books: [Book]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: root.appending(path: "library.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func savePages(_ images: [Data], filter: ScanFilter) throws -> [ScanPage] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var written: [URL] = []
        do {
            return try images.map { data in
                try autoreleasepool {
                    let id = UUID().uuidString
                    let original = "\(id)-original.jpg", name = "\(id).jpg", thumb = "\(id)-thumb.jpg"
                    let rendered = try ImageProcessor.render(data, filter: filter)
                    for (filename, bytes) in [(original, data), (name, rendered), (thumb, try Self.thumbnail(rendered))] {
                        let url = root.appending(path: filename)
                        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                        written.append(url)
                    }
                    return ScanPage(imageName: name, originalName: original, thumbnailName: thumb, filter: filter)
                }
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    func refilter(_ page: ScanPage, filter: ScanFilter) throws -> ScanPage {
        let original = try Data(contentsOf: root.appending(path: page.originalName))
        let data = try ImageProcessor.render(original, filter: filter)
        let id = UUID().uuidString
        var result = page
        result.imageName = "\(id).jpg"
        result.thumbnailName = "\(id)-thumb.jpg"
        result.filter = filter
        result.text = ""
        try data.write(to: root.appending(path: result.imageName), options: .atomic)
        try Self.thumbnail(data).write(to: root.appending(path: result.thumbnailName), options: .atomic)
        return result
    }

    func data(for page: ScanPage) throws -> Data { try Data(contentsOf: root.appending(path: page.imageName)) }

    func removeUnused(_ books: [Book]) throws {
        let names = Set(books.flatMap(\.pages).flatMap { [$0.imageName, $0.originalName, $0.thumbnailName] })
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.pathExtension == "jpg" && !names.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func export(_ book: Book) throws -> URL {
        guard !book.pages.isEmpty else { throw ScanError.message("먼저 페이지를 추가해 주세요.") }
        for page in book.pages {
            guard FileManager.default.fileExists(atPath: root.appending(path: page.imageName).path) else { throw ScanError.message("누락된 페이지 이미지가 있어 PDF를 만들 수 없습니다.") }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "Exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "BookScan-\(book.id.uuidString).pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: book.title, kCGPDFContextCreator as String: "BookScan3"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        try renderer.writePDF(to: url) { context in
            for page in book.pages {
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: root.appending(path: page.imageName).path) else { return }
                    let width: CGFloat = 595
                    let height = width * image.size.height / image.size.width
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
        }
        return url
    }

    private static func thumbnail(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
        else { throw ScanError.message("미리보기 이미지를 만들 수 없습니다.") }
        return jpeg
    }
}
