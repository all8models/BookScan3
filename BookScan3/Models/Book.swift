import Foundation

struct ScanPage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var imageName: String
    var originalName: String
    var thumbnailName: String
    var text: String = ""
    var filter: ScanFilter = .original
    var createdAt = Date()
    // 이전 버전(v1)에서 저장된 라이브러리 메타데이터와의 하위 호환 디코딩을 위해 옵셔널로 선언
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
