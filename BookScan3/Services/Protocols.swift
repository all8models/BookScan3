import Foundation
import AVFoundation

/// Protocol defining storage operations for BookScan3.
/// Decouples view models and views from the concrete StorageManager implementation.
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

/// Protocol defining camera capture and preview control operations.
protocol CameraServiceProtocol: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    var onDetection: (@Sendable (Quad?, Bool, CGFloat, CGFloat, SpreadDetection?) -> Void)? { get set }
    func setSpreadMode(_ enabled: Bool)
    func start() async throws
    func stop()
    func capture() async throws -> Data
}

/// Protocol defining optical character recognition operations.
protocol OCRServiceProtocol: Sendable {
    func recognize(_ data: Data) async throws -> String
}
