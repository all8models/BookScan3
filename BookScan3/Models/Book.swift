import Foundation

struct ScanPage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var imageName: String
    var originalName: String
    var thumbnailName: String
    var text: String = ""
    var filter: ScanFilter = .original
    var createdAt = Date()
    // Optional fields keep libraries written by version 1 decodable.
    var captureID: UUID?
    var captureSide: Int?
}

struct Book: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var pages: [ScanPage] = []
}

enum ScanFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, vivid, grayscale, blackWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "원본"
        case .vivid: "선명하게"
        case .grayscale: "회색조"
        case .blackWhite: "흑백"
        }
    }
}

enum ScanError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
