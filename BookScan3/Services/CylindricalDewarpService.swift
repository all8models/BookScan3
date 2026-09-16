import CoreImage

/// 경량 수평 원통형 근사 곡면 보정 서비스.
/// 3D 메시 추론이나 손가락 제거 없이, 수학적 원통형 모델(Cylindrical projection)을 적용하여 제본선 부근의 왜곡을 보정합니다.
enum CylindricalDewarpService {
    /// Metal 라이브러리가 없거나 로드 실패 시 사용하는 CIKL(Core Image Kernel Language) 대체 커널.
    /// iOS 12부터 CIKL init(source:)가 Deprecated되었으나, 프로젝트 빌드 설정의 CI_SILENCE_GL_DEPRECATION 플래그를 통해 안전하게 유지됩니다.
    private static let fallbackKernel = CIWarpKernel(source: """
        kernel vec2 cylindrical(float width, float angle, float bindingOnLeft) {
            vec2 p = destCoord();
            float u = clamp(p.x / width, 0.0, 1.0);
            float v = mix(u, 1.0 - u, bindingOnLeft);
            float mapped = sin(v * angle) / sin(angle);
            mapped = mix(mapped, 1.0 - mapped, bindingOnLeft);
            return vec2(mapped * width, p.y);
        }
        """)

    /// 번들에 컴파일된 Metal 라이브러리(default.metallib)의 'cylindrical' 커널을 우선 로드하며,
    /// 없을 경우 fallbackKernel(CIKL)로 자동 대체(Fallback)합니다.
    private static let kernel: CIWarpKernel? = {
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url),
           let metalKernel = try? CIWarpKernel(functionName: "cylindrical", fromMetalLibraryData: data) {
            return metalKernel
        }
        return fallbackKernel
    }()

    /// 이미지에 수평 원통형 곡면 보정을 적용합니다.
    /// - Parameters:
    ///   - image: 보정할 원본 CIImage
    ///   - strength: 곡면 보정 강도 (0.0 ~ 1.0)
    ///   - bindingOnLeft: 제본선(책의 안쪽 여백)이 왼쪽에 위치하는지 여부 (왼쪽 페이지: false, 오른쪽 페이지: true 등)
    /// - Returns: 곡면 보정이 적용된 CIImage
    static func dewarp(_ image: CIImage, strength: Double, bindingOnLeft: Bool) throws -> CIImage {
        // 보정 강도가 미미할 경우 불필요한 연산 없이 원본 반환
        guard strength > 0.001 else { return image }
        
        // 원점을 (0, 0)으로 정규화
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let extent = normalized.extent
        let angle = 0.15 + min(1, max(0, strength)) * 1.05
        
        // 커널 실행 및 좌표 왜곡 적용
        guard let output = kernel?.apply(extent: extent, roiCallback: { _, _ in extent }, image: normalized, arguments: [extent.width, angle, bindingOnLeft ? 1.0 : 0.0]) else {
            throw ScanError.message("기본 곡면 보정을 실행할 수 없습니다. 곡면 보정을 끄고 다시 촬영해 주세요.")
        }
        return output.cropped(to: extent)
    }
}

