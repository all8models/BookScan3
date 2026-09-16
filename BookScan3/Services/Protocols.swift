import Foundation
import AVFoundation

/// BookScan3의 파일 저장 및 영속성 작업을 정의하는 프로토콜.
/// 뷰모델과 뷰가 구체적인 StorageManager 구현체에 직접 의존하지 않도록 분리(DIP)합니다.
protocol StorageServiceProtocol: Sendable {
    nonisolated var root: URL { get }
    func load() async throws -> [Book]
    func save(_ books: [Book]) async throws
    func savePages(_ images: [Data], filter: ScanFilter) async throws -> [ScanPage]
    func refilter(_ page: ScanPage, filter: ScanFilter) async throws -> ScanPage
    func data(for page: ScanPage) async throws -> Data
    func createCapture(data: Data, bookID: UUID, filter: ScanFilter, curvature: Double) async throws -> CaptureRecord
    func saveCapture(_ record: CaptureRecord) async throws
    func capture(_ id: UUID) async throws -> CaptureRecord
    func source(_ record: CaptureRecord) async throws -> Data
    func captures() async throws -> [CaptureRecord]
    func deleteCapture(_ record: CaptureRecord) async throws
    func removeUnused(_ books: [Book]) async throws
    func export(_ book: Book) async throws -> URL
}

/// 카메라 캡처 및 프리뷰 제어 작업을 정의하는 프로토콜.
protocol CameraServiceProtocol: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    var onDetection: (@Sendable (Quad?, Bool, CGFloat, CGFloat, SpreadDetection?) -> Void)? { get set }
    func setSpreadMode(_ enabled: Bool)
    func start() async throws
    func stop()
    func capture() async throws -> Data
}

/// 광학 문자 인식(OCR) 작업을 정의하는 프로토콜.
protocol OCRServiceProtocol: Sendable {
    func recognize(_ data: Data) async throws -> String
}

