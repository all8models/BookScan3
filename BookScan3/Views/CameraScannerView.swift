import SwiftUI
import AVFoundation
import PhotosUI

struct CameraScannerView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var scanner = ScannerViewModel()
    @State private var photo: PhotosPickerItem?
    @State private var review: CaptureRecord?
    let bookID: UUID
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width > 750
                Group {
                    if wide { HStack(spacing: 0) { preview; controls.frame(width: 300) } }
                    else { VStack(spacing: 0) { preview; controls } }
                }.background(Color(white: 0.08))
            }
            .navigationTitle("책 스캔").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("완료") { dismiss() }.disabled(scanner.capturing || library.busy) }
                ToolbarItem(placement: .primaryAction) { Text("\(library.books.first { $0.id == bookID }?.pages.count ?? 0)페이지 저장됨").font(.subheadline.monospacedDigit()) }
            }
            .task {
                scanner.onCapture = { data, hint in await save(data, hint: hint) }
                await scanner.start()
            }
            .onDisappear { scanner.stop() }
            .sheet(item: $review, onDismiss: { scanner.reviewing = false }) { record in
                SpreadReviewView(record: record).environmentObject(library)
            }
            .onChange(of: scanner.split) { _, value in scanner.camera.setSpreadMode(value); scanner.spread = nil; scanner.quad = nil }
            .onChange(of: phase) { _, phase in if phase == .active { Task { await scanner.start() } } else { scanner.stop() } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    scanner.capturing = true
                    defer { scanner.capturing = false; photo = nil }
                    do { if let data = try await item.loadTransferable(type: Data.self) { await save(data) } }
                    catch { scanner.error = error.localizedDescription }
                }
            }
            .alert("저장하지 못했습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("확인") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }
    private var preview: some View {
        ZStack {
            CameraPreview(session: scanner.camera.session, quad: scanner.quad, aspect: scanner.aspect, rotation: scanner.rotation, spread: scanner.split ? scanner.spread : nil)
            if !scanner.ready {
                VStack(spacing: 16) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 56, weight: .ultraLight))
                    Text(scanner.error ?? "카메라 준비 중…").font(.callout).multilineTextAlignment(.center).frame(maxWidth: 380)
                    if scanner.error != nil { Button("다시 시도") { Task { await scanner.start() } }.buttonStyle(.bordered) }
                }.foregroundStyle(.white).padding(28)
            }
            VStack {
                Label(scanner.split ? (scanner.spread?.canAutoSave == true ? "양쪽 페이지를 찾았어요 · 잠시 고정해 주세요" : "양쪽 페이지가 모두 보이도록 맞춰 주세요") : (scanner.quad == nil ? "문서 전체가 보이도록 맞춰 주세요" : "문서를 찾았어요 · 잠시 고정해 주세요"), systemImage: "viewfinder")
                    .font(.subheadline).padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 22)
                Spacer()
                if scanner.capturing || library.busy { ProgressView(library.progress.isEmpty ? "촬영 중…" : library.progress).padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 22) }
            }.padding(.horizontal)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) { Text("좋은 스캔의 시작").font(.title2.weight(.semibold)); Text("책을 평평하게 펼치고\n빛이 고르게 닿도록 해 주세요.").font(.subheadline).foregroundStyle(.secondary) }
                Picker("페이지 모드", selection: $scanner.split) { Text("한 페이지").tag(false); Text("펼친 책").tag(true) }.pickerStyle(.segmented)
                if scanner.split {
                    Toggle("촬영마다 경계 확인", isOn: $scanner.reviewEveryCapture)
                    Toggle("접힘선 자동 찾기", isOn: $scanner.automaticSpine)
                    if !scanner.automaticSpine {
                        Slider(value: $scanner.spine, in: 0.25...0.75).accessibilityLabel("왼쪽 페이지 비율")
                        Text("왼쪽 \(Int(scanner.spine * 100))% · 오른쪽 \(100 - Int(scanner.spine * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Toggle("기본 곡면 보정", isOn: $scanner.dewarp)
                    if scanner.dewarp {
                        Slider(value: $scanner.curvature, in: 0.05...1).accessibilityLabel("곡면 보정 강도")
                        Text("접힘선 근처의 눌린 글자 폭을 펴줍니다. 약한 강도부터 시작해 주세요.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("컬러 필터", selection: $scanner.filter) { ForEach(ScanFilter.allCases) { Text($0.title).tag($0) } }
                Toggle("자동 촬영", isOn: $scanner.automatic)
                Text("안정된 문서를 자동으로 촬영합니다. 다음 촬영 전 책을 움직이거나 화면 밖으로 뺐다가 다시 놓아 주세요.").font(.caption).foregroundStyle(.secondary)
                Button { Task { await scanner.capture() } } label: {
                    ZStack { Circle().stroke(Theme.accent, lineWidth: 3).frame(width: 78, height: 78); Circle().fill(Theme.accent).frame(width: 64, height: 64); Image(systemName: "camera.fill").foregroundStyle(.white).font(.title2) }.frame(maxWidth: .infinity)
                }.accessibilityLabel("촬영").disabled(!scanner.ready || scanner.capturing || library.busy)
                PhotosPicker(selection: $photo, matching: .images) { Label("사진에서 가져오기", systemImage: "photo") }.frame(maxWidth: .infinity)
                Text("원근 보정 · 양면 분할 · 기기 내 저장").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24).disabled(scanner.capturing || library.busy)
        }.background(Theme.paper)
    }
    private func save(_ data: Data, hint: SpreadCaptureHint? = nil) async {
        if let record = await library.add(data: data, to: bookID, split: scanner.split, spine: scanner.automaticSpine ? nil : scanner.spine, filter: scanner.filter, curvature: scanner.dewarp ? scanner.curvature : 0, forceReview: scanner.reviewEveryCapture, hint: hint) {
            scanner.reviewing = true
            review = record
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let quad: Quad?
    let aspect: CGFloat
    let rotation: CGFloat
    let spread: SpreadDetection?
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(); view.preview.session = session; return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.quad = quad; uiView.aspect = aspect; uiView.rotation = rotation; uiView.spread = spread; uiView.setNeedsLayout() }
}

private final class PreviewView: UIView {
    let preview = AVCaptureVideoPreviewLayer()
    private let outline = CAShapeLayer()
    var quad: Quad?
    var aspect: CGFloat = 0.75
    var rotation: CGFloat = 90
    var spread: SpreadDetection?
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        layer.addSublayer(preview); layer.addSublayer(outline)
        outline.strokeColor = UIColor.systemMint.cgColor
        outline.fillColor = UIColor.systemMint.withAlphaComponent(0.1).cgColor
        outline.lineWidth = 2
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        guard let quad else { outline.path = nil; return }
        // Match the actual rotated analysis buffer; avoid assuming a camera aspect ratio.
        let rect = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: bounds)
        let points = quad.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
        let path = UIBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
        if let spread, spread.geometry.isValid, spread.confidence > 0 {
            let p = spread.geometry.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
            path.removeAllPoints(); path.move(to: p[0]); p.dropFirst().forEach { path.addLine(to: $0) }; path.close()
            path.move(to: p[1]); path.addLine(to: p[4])
            outline.strokeColor = (spread.canAutoSave ? UIColor.systemMint : UIColor.systemOrange).cgColor
        } else { outline.strokeColor = UIColor.systemMint.cgColor }
        outline.path = path.cgPath
    }
}
