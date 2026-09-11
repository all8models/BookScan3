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
    @State var bookID: UUID
    @State private var settings = false
    @State private var results = false
    @AppStorage("reviewEveryCapture") private var reviewPreference = false
    var body: some View {
        NavigationStack {
            ZStack {
                preview
                VStack {
                    Menu {
                        ForEach(library.books) { book in
                            Button(book.title) { bookID = book.id }
                        }
                    } label: {
                        Label(library.books.first { $0.id == bookID }?.title ?? "책 선택", systemImage: "folder")
                            .padding(12).background(.black.opacity(0.55), in: Capsule())
                    }.padding(.top, 12)
                    Spacer()
                    HStack {
                        VStack(spacing: 12) {
                            Button("1페이지") { scanner.split = false }.foregroundStyle(scanner.split ? .white : .yellow)
                            Button("2페이지") { scanner.split = true }.foregroundStyle(scanner.split ? .yellow : .white)
                        }.font(.headline).padding(14).background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }.padding()
                    Spacer()
                    captureBar
                }.foregroundStyle(.white)
            }.background(.black)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("서재", systemImage: "folder") { dismiss() }.disabled(scanner.capturing || library.busy) }
                ToolbarItem(placement: .primaryAction) { Button("설정", systemImage: "gearshape") { settings = true } }
            }
            .sheet(isPresented: $settings, onDismiss: { scanner.reviewing = false }) {
                NavigationStack { controls.navigationTitle("촬영 설정").toolbar { Button("완료") { settings = false } } }
            }
            .sheet(isPresented: $results, onDismiss: { scanner.reviewing = false }) {
                NavigationStack { BookDetailView(bookID: bookID).toolbar { Button("촬영으로") { results = false } } }
            }
            .onChange(of: settings) { _, value in scanner.reviewing = value }
            .onChange(of: results) { _, value in scanner.reviewing = value }
            .onChange(of: scanner.reviewEveryCapture) { _, value in reviewPreference = value }
            .task {
                scanner.reviewEveryCapture = reviewPreference
                scanner.onCapture = { data, hint in await save(data, hint: hint) }
                await scanner.start()
            }
            .onDisappear { scanner.stop() }
            .fullScreenCover(item: $review, onDismiss: { scanner.reviewing = false }) { record in
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
                    .font(.subheadline).padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 80)
                Spacer()
                if scanner.capturing || library.busy { ProgressView(library.progress.isEmpty ? "촬영 중…" : library.progress).padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 22) }
            }.padding(.horizontal)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
    private var captureBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Button { scanner.automatic.toggle() } label: { Label("자동", systemImage: "camera.viewfinder") }.tint(scanner.automatic ? .yellow : .white)
                Button { scanner.reviewEveryCapture.toggle() } label: { Label("경계 확인", systemImage: "crop") }.tint(scanner.reviewEveryCapture ? .yellow : .white)
                Menu { ForEach(ScanFilter.allCases) { filter in Button(filter.title) { scanner.filter = filter } } } label: { Image(systemName: "camera.filters").accessibilityLabel("필터") }
            }.font(.subheadline).padding(12).background(.black.opacity(0.55), in: Capsule())
            HStack(spacing: 28) {
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo").font(.title).frame(width: 48, height: 48) }.accessibilityLabel("사진에서 가져오기")
                Button { results = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let page = library.books.first(where: { $0.id == bookID })?.pages.last {
                            PageThumbnail(url: library.root.appending(path: page.thumbnailName)).frame(width: 54, height: 64).clipped()
                        } else { Image(systemName: "square.stack").frame(width: 54, height: 64) }
                        Text("\(library.books.first { $0.id == bookID }?.pages.count ?? 0)").font(.caption).padding(3).background(.black.opacity(0.7))
                    }
                }.accessibilityLabel("최근 촬영 결과")
                Button { Task { await scanner.capture() } } label: {
                    Circle().fill(.white).frame(width: 68, height: 68).padding(7).overlay(Circle().stroke(.white, lineWidth: 4))
                }.accessibilityLabel("촬영").disabled(!scanner.ready)
            }
        }.padding(20).frame(maxWidth: .infinity).background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            .disabled(scanner.capturing || library.busy)
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
    private let seam = CAShapeLayer()
    private let numbers = [CATextLayer(), CATextLayer()]
    var quad: Quad?
    var aspect: CGFloat = 0.75
    var rotation: CGFloat = 90
    var spread: SpreadDetection?
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        layer.addSublayer(preview); layer.addSublayer(outline); layer.addSublayer(seam)
        seam.strokeColor = UIColor.white.cgColor; seam.lineWidth = 2; seam.lineDashPattern = [8, 6]
        seam.fillColor = UIColor.clear.cgColor
        for (index, number) in numbers.enumerated() {
            number.string = "\(index + 1)"; number.fontSize = 36; number.alignmentMode = .center
            number.foregroundColor = UIColor.white.cgColor; number.contentsScale = UIScreen.main.scale
            layer.addSublayer(number)
        }
        outline.strokeColor = UIColor.systemMint.cgColor
        outline.fillColor = UIColor.systemMint.withAlphaComponent(0.1).cgColor
        outline.lineWidth = 2
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        seam.path = nil; numbers.forEach { $0.isHidden = true }
        guard let quad else { outline.path = nil; return }
        // Match the actual rotated analysis buffer; avoid assuming a camera aspect ratio.
        let rect = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: bounds)
        let points = quad.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
        let path = UIBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
        if let spread, spread.geometry.isValid, spread.confidence > 0 {
            let p = spread.geometry.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
            path.removeAllPoints(); path.move(to: p[0]); p.dropFirst().forEach { path.addLine(to: $0) }; path.close()
            let divider = UIBezierPath(); divider.move(to: p[1]); divider.addLine(to: p[4]); seam.path = divider.cgPath
            for (index, indices) in [[0, 1, 4, 5], [1, 2, 3, 4]].enumerated() {
                let center = indices.reduce(CGPoint.zero) { CGPoint(x: $0.x + p[$1].x / 4, y: $0.y + p[$1].y / 4) }
                numbers[index].frame = CGRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48); numbers[index].isHidden = false
            }
            outline.strokeColor = (spread.canAutoSave ? UIColor.systemMint : UIColor.systemOrange).cgColor
        } else { outline.strokeColor = UIColor.systemMint.cgColor }
        outline.path = path.cgPath
    }
}
