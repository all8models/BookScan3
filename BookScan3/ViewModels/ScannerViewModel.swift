import SwiftUI

@MainActor
final class ScannerViewModel: ObservableObject {
    let camera = CameraService()
    @Published var quad: Quad?
    @Published var aspect: CGFloat = 0.75
    @Published var rotation: CGFloat = 90
    @Published var ready = false
    @Published var capturing = false
    @Published var automatic = false
    @Published var split = true
    @Published var automaticSpine = true
    @Published var spine = 0.5
    @Published var dewarp = false
    @Published var curvature = 0.4
    @Published var filter: ScanFilter = .original
    @Published var error: String?
    var onCapture: ((Data) async -> Void)?
    private var active = false

    init() {
        camera.onDetection = { [weak self] quad, trigger, aspect, rotation in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.quad = quad
                self.aspect = aspect; self.rotation = rotation
                if trigger, self.automatic, !self.capturing { await self.capture() }
            }
        }
    }
    func start() async {
        active = true
        do {
            try await camera.start()
            if active { ready = true; error = nil } else { camera.stop() }
        } catch { self.error = error.localizedDescription }
    }
    func stop() { active = false; ready = false; camera.stop() }
    func capture() async {
        guard active, ready, !capturing else { return }
        capturing = true; defer { capturing = false }
        do { let data = try await camera.capture(); await onCapture?(data) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
