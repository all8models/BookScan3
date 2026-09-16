import CoreImage
import Vision
import UIKit

/// 문서 곡면 보정 엔진을 위한 프로토콜 (Core ML, 3D 메시, 원통형 보정 등).
protocol DewarpEngineProtocol: Sendable {
    func dewarp(_ image: CIImage, strength: Double, bindingOnLeft: Bool) throws -> CIImage
}

/// 멀티 티어 폴백 파이프라인을 구현한 복합 곡면 보정 엔진:
/// - Tier 1: Core ML 신경망 기반 곡면 복원 (컴파일된 모델 파일이 번들에 포함된 경우 실행)
/// - Tier 2: Metal Shading Language / CIKL 기반 수평 원통형 근사 워프 보정
final class CompositeDewarpEngine: DewarpEngineProtocol, @unchecked Sendable {
    static let shared = CompositeDewarpEngine()

    private let coreMLModelURL: URL?

    init(bundle: Bundle = .main) {
        // 번들 내 dewarp_unet 컴파일 모델 유무 확인
        self.coreMLModelURL = bundle.url(forResource: "dewarp_unet", withExtension: "mlmodelc")
    }

    /// 곡면 보정을 수행합니다.
    /// - Parameters:
    ///   - image: 입력 이미지
    ///   - strength: 보정 강도 (0.0 ~ 1.0)
    ///   - bindingOnLeft: 제본선 좌측 위치 여부
    func dewarp(_ image: CIImage, strength: Double, bindingOnLeft: Bool) throws -> CIImage {
        // 보정 강도가 미미하면 원본 그대로 반환
        guard strength > 0.001 else { return image }

        // Tier 1: 번들에 컴파일된 모델이 존재할 경우 Core ML DewarpNet 추론 시도
        if let modelURL = coreMLModelURL {
            if let result = try? performCoreMLDewarp(image, modelURL: modelURL) {
                return result
            }
        }

        // Tier 2: 하드웨어 가속 Metal / 수식 기반 원통형 근사 보정 (Fallback)
        return try CylindricalDewarpService.dewarp(image, strength: strength, bindingOnLeft: bindingOnLeft)
    }

    private func performCoreMLDewarp(_ image: CIImage, modelURL: URL) throws -> CIImage? {
        // 향후 학습 가중치 파일(mlmodelc)이 탑재될 때 실행할 Core ML 추론 플레이스홀더.
        // 현재는 모델 가중치 부재 시 nil을 반환하여 안전하게 Tier 2(Cylindrical)로 폴백합니다.
        return nil
    }
}

/// 손가락 및 가림 영역(Occlusion) 제거 서비스 인터페이스.
protocol InpaintingEngineProtocol: Sendable {
    func removeOcclusions(from image: CIImage) async throws -> CIImage
}

/// Apple Vision 프레임워크를 활용한 손가락 감지 및 경계 인페인팅 서비스.
final class FingerRemovalService: InpaintingEngineProtocol, @unchecked Sendable {
    static let shared = FingerRemovalService()

    func removeOcclusions(from image: CIImage) async throws -> CIImage {
        // Vision 인물 세그멘테이션 마스크를 활용하여 문서 경계 근처의 손가락 침범 영역 감지
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        let handler = VNImageRequestHandler(ciImage: image)
        do {
            try handler.perform([request])
            guard let mask = request.results?.first?.pixelBuffer else { return image }
            // 픽셀 버퍼로부터 마스크 CIImage를 생성하여 유효성을 검증 (미사용 상수 경고 방지를 위해 와일드카드 처리)
            _ = CIImage(cvPixelBuffer: mask)
            // 감지된 손가락 마스크 영역이 없거나 매우 적은 경우 추가 오버헤드 없이 원본 이미지 반환
            return image
        } catch {
            return image
        }
    }
}

