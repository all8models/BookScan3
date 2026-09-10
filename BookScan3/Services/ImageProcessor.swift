import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

struct Quad: Equatable, Sendable {
    var points: [CGPoint] // top-left, top-right, bottom-right, bottom-left; Vision coordinates
    init(_ observation: VNRectangleObservation) {
        points = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
    }
    init(points: [CGPoint]) { self.points = points }
    var area: CGFloat {
        abs((0..<4).reduce(CGFloat.zero) { sum, i in
            let a = points[i], b = points[(i + 1) % 4]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }
    func distance(to other: Quad) -> CGFloat {
        zip(points, other.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }
}

struct KalmanQuadFilter {
    private var value: Quad?
    private var variance: CGFloat = 1
    mutating func reset() { value = nil; variance = 1 }
    mutating func update(_ measurement: Quad) -> Quad {
        guard let previous = value else { value = measurement; return measurement }
        let innovation = measurement.distance(to: previous)
        variance += innovation > 0.025 ? 0.08 : 0.0001
        let gain = variance / (variance + 0.002)
        let result = Quad(points: zip(previous.points, measurement.points).map { a, b in
            CGPoint(x: a.x + gain * (b.x - a.x), y: a.y + gain * (b.y - a.y))
        })
        variance *= 1 - gain
        value = result
        return result
    }
}

struct AutoCaptureGate {
    private var previous: Quad?
    private var stableSince: TimeInterval?
    private var armed = true
    private var lastCapture: TimeInterval = -10
    mutating func reset() { self = AutoCaptureGate() }
    mutating func update(_ quad: Quad?, sharpness: Double, time: TimeInterval, additionalMotion: CGFloat = 0) -> Bool {
        guard let quad else { previous = nil; stableSince = nil; armed = true; return false }
        let motion = max(additionalMotion, previous.map { quad.distance(to: $0) } ?? 1)
        previous = quad
        if motion > 0.035 { armed = true }
        guard armed, quad.area > 0.15, sharpness > 0.003, motion < 0.009 else { stableSince = nil; return false }
        if stableSince == nil { stableSince = time }
        if time - (stableSince ?? time) >= 0.6, time - lastCapture > 2 {
            lastCapture = time; armed = false; stableSince = nil
            return true
        }
        return false
    }
}

enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func detect(_ image: CIImage) throws -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(ciImage: image).perform([request])
        return request.results?.first.flatMap { $0.confidence > 0.5 ? Quad($0) : nil }
    }

    static func correct(_ image: CIImage, quad: Quad) -> CIImage {
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        let p = quad.points.map { CGPoint(x: image.extent.minX + $0.x * image.extent.width, y: image.extent.minY + $0.y * image.extent.height) }
        filter.topLeft = p[0]; filter.topRight = p[1]; filter.bottomRight = p[2]; filter.bottomLeft = p[3]
        return filter.outputImage ?? image
    }

    static func process(_ data: Data, split: Bool, spine: Double?, curvature: Double = 0) throws -> [Data] {
        if split {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ScanError.message("이미지를 읽을 수 없습니다.") }
            let detection = try BookSpreadDetector.detect(image, manualSpine: spine)
            guard detection.canAutoSave else { throw ScanError.message("양쪽 페이지의 경계를 먼저 확인해 주세요.") }
            return try processSpread(data, geometry: detection.geometry, curvature: curvature)
        }
        return try autoreleasepool {
            guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ScanError.message("이미지를 읽을 수 없습니다.") }
            if let quad = try detect(image) { image = correct(image, quad: quad) }
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            return [try jpeg(image)]
        }
    }

    static func processSpread(_ data: Data, geometry: SpreadGeometry, curvature: Double = 0) throws -> [Data] {
        guard geometry.isValid else { throw ScanError.message("좌우 경계가 겹치거나 뒤집혀 있어요. 여섯 점을 다시 맞춰 주세요.") }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ScanError.message("촬영 원본을 읽을 수 없습니다.") }
        return try [geometry.left, geometry.right].enumerated().map { index, quad in
            try autoreleasepool {
                let corrected = correct(image, quad: quad)
                return try jpeg(CylindricalDewarpService.dewarp(corrected, strength: curvature, bindingOnLeft: index == 1))
            }
        }
    }

    static func render(_ data: Data, filter: ScanFilter) throws -> Data {
        guard let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ScanError.message("이미지 변환에 실패했습니다.") }
        let output: CIImage
        switch filter {
        case .original: return data
        case .vivid: output = input.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.25, kCIInputBrightnessKey: 0.04, kCIInputSaturationKey: 0.8])
        case .grayscale: output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .blackWhite:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.55])
        }
        return try jpeg(output)
    }

    static func jpeg(_ image: CIImage) throws -> Data {
        guard let cg = context.createCGImage(image, from: image.extent), let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { throw ScanError.message("이미지를 저장할 수 없습니다.") }
        return data
    }
}

actor OCRService {
    func recognize(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"].filter { supported.contains($0) }
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
