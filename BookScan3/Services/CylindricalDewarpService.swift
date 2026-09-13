import CoreImage

/// Lightweight, user-adjustable horizontal cylindrical approximation.
/// It does not infer a 3D surface or remove fingers; learned models are not bundled.
enum CylindricalDewarpService {
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

    private static let kernel: CIWarpKernel? = {
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url),
           let metalKernel = try? CIWarpKernel(functionName: "cylindrical", fromMetalLibraryData: data) {
            return metalKernel
        }
        return fallbackKernel
    }()

    static func dewarp(_ image: CIImage, strength: Double, bindingOnLeft: Bool) throws -> CIImage {
        guard strength > 0.001 else { return image }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let extent = normalized.extent
        let angle = 0.15 + min(1, max(0, strength)) * 1.05
        guard let output = kernel?.apply(extent: extent, roiCallback: { _, _ in extent }, image: normalized, arguments: [extent.width, angle, bindingOnLeft ? 1.0 : 0.0]) else {
            throw ScanError.message("기본 곡면 보정을 실행할 수 없습니다. 곡면 보정을 끄고 다시 촬영해 주세요.")
        }
        return output.cropped(to: extent)
    }
}
