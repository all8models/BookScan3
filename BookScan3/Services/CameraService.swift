import AVFoundation
import CoreImage

final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, CameraServiceProtocol, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "camera.analysis", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<Data, Error>?
    private var lastAnalysis: Double = 0
    private var smoother = KalmanQuadFilter()
    private var gate = AutoCaptureGate()
    private var spreadMode = true
    private var previousSpread: SpreadGeometry?
    private var configured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    var onDetection: (@Sendable (Quad?, Bool, CGFloat, CGFloat, SpreadDetection?) -> Void)?

    func setSpreadMode(_ enabled: Bool) {
        analysisQueue.async { self.spreadMode = enabled; self.previousSpread = nil; self.gate.reset(); self.smoother.reset() }
    }

    func start() async throws {
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed = permission == .authorized ? true : (permission == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : false)
        guard allowed else { throw ScanError.message("설정에서 BookScan3의 카메라 접근을 허용해 주세요. 사진 가져오기는 권한 없이 사용할 수 있습니다.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.configured { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func configure() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw ScanError.message("이 기기에서는 카메라를 사용할 수 없습니다. 사진을 가져와 스캔할 수 있습니다.") }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw ScanError.message("카메라 연결에 실패했습니다.") }
        session.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        video.setSampleBufferDelegate(self, queue: analysisQueue)
        guard session.canAddOutput(video), session.canAddOutput(output) else {
            session.removeInput(input)
            throw ScanError.message("사진 출력을 구성할 수 없습니다.")
        }
        session.addOutput(video); session.addOutput(output)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self, weak video] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { [weak self, weak video] in
                guard let self else { return }
                for connection in [video?.connection(with: .video), self.output.connection(with: .video)].compactMap({ $0 }) {
                    if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                }
            }
        }
        configured = true
    }
    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            if let pending = self.continuation { self.continuation = nil; pending.resume(throwing: CancellationError()) }
        }
        analysisQueue.async { self.gate.reset(); self.smoother.reset(); self.previousSpread = nil }
    }
    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.session.isRunning, self.continuation == nil else { continuation.resume(throwing: ScanError.message("카메라가 준비되지 않았습니다.")); return }
                self.continuation = continuation
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        sessionQueue.async {
            guard let pending = self.continuation else { return }
            self.continuation = nil
            if let error { pending.resume(throwing: error) }
            else if let data { pending.resume(returning: data) }
            else { pending.resume(throwing: ScanError.message("촬영한 사진을 읽지 못했습니다.")) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        sessionQueue.async { self.continuation?.resume(throwing: error); self.continuation = nil }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // Analysis is intentionally throttled independently of the smooth camera preview.
        guard time - lastAnalysis > 0.12, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = time
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 720 / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let spread = spreadMode ? try? BookSpreadDetector.detect(small) : nil
            let raw: Quad? = spreadMode ? ((spread?.confidence ?? 0) > 0 ? spread?.geometry.outer : nil) : try? ImageProcessor.detect(small)
            let quad = raw.map { smoother.update($0) }
            if quad == nil { smoother.reset() }
            let motion = spread.flatMap { value in previousSpread.map { value.geometry.distance(to: $0) } } ?? 1
            previousSpread = spread?.geometry
            let accepted = spreadMode ? (spread?.canAutoSave == true ? raw : nil) : raw
            let ready = gate.update(accepted, sharpness: Self.sharpness(buffer), time: time, additionalMotion: spreadMode ? motion : 0)
            onDetection?(quad, ready, image.extent.width / image.extent.height, connection.videoRotationAngle, spread)
        }
    }
    private static func sharpness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var sum = 0.0, count = 0.0
        for y in Swift.stride(from: height / 4, to: height * 3 / 4, by: 8) {
            for x in Swift.stride(from: width / 4, to: width * 3 / 4, by: 8) {
                let i = y * stride + x
                let lap = Double(Int(ptr[i - 1]) + Int(ptr[i + 1]) + Int(ptr[i - stride]) + Int(ptr[i + stride]) - 4 * Int(ptr[i])) / 255
                sum += lap * lap; count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }
}
