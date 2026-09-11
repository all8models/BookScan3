import SwiftUI
import AVFoundation
import ImageIO

struct SpreadReviewView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var record: CaptureRecord
    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var selectedHandle = 0
    private let labels = ["왼쪽 위", "접힘선 위", "오른쪽 위", "오른쪽 아래", "접힘선 아래", "왼쪽 아래"]

    init(record: CaptureRecord) {
        var safe = record
        if safe.geometry.points.count != 6 || !safe.geometry.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) { safe.geometry = .guide }
        _record = State(initialValue: safe)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(record.note).font(.callout).multilineTextAlignment(.center).padding(.horizontal)
                GeometryReader { proxy in
                    if let image {
                        let rect = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 26, dy: 26))
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image).resizable().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                            Path { path in
                                let p = screenPoints(rect)
                                guard p.count == 6 else { return }
                                path.move(to: p[0]); for point in p.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
                            }.fill(Theme.accent.opacity(0.12))
                            Path { path in
                                let p = screenPoints(rect)
                                guard p.count == 6 else { return }
                                path.move(to: p[0]); for point in p.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
                                path.move(to: p[1]); path.addLine(to: p[4])
                            }.stroke(record.geometry.isValid ? Theme.accent : Color.red, style: StrokeStyle(lineWidth: 2))
                            ForEach(0..<6) { index in
                                let point = screenPoints(rect)[index]
                                Circle().fill(index == 1 || index == 4 ? Color.orange : Theme.accent)
                                    .frame(width: 22, height: 22).overlay(Circle().stroke(.white, lineWidth: 2))
                                    .frame(width: 48, height: 48).contentShape(Rectangle()).position(point)
                                    .accessibilityLabel(labels[index]).accessibilityIdentifier("spreadHandle\(index)")
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("spreadCanvas")).onChanged { value in
                                        selectedHandle = index
                                        record.geometry.points[index] = CGPoint(x: min(1, max(0, (value.location.x - rect.minX) / rect.width)), y: min(1, max(0, 1 - (value.location.y - rect.minY) / rect.height)))
                                    })
                            }
                            Text("왼쪽 페이지").font(.caption.bold()).foregroundStyle(.white).padding(5).background(.black.opacity(0.55), in: Capsule()).position(x: rect.minX + rect.width * 0.25, y: rect.midY)
                            Text("오른쪽 페이지").font(.caption.bold()).foregroundStyle(.white).padding(5).background(.black.opacity(0.55), in: Capsule()).position(x: rect.minX + rect.width * 0.75, y: rect.midY)
                        }.coordinateSpace(name: "spreadCanvas")
                    } else if let loadError { ContentUnavailableView("원본을 열 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(loadError)) }
                    else { ProgressView("원본 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.background(Color(white: 0.12)).accessibilityIdentifier("spreadCanvas")
                if !record.geometry.isValid { Text("선이 교차하지 않도록 모서리와 접힘선을 맞춰 주세요.").font(.caption).foregroundStyle(.red) }
                HStack {
                    Picker("조정할 점", selection: $selectedHandle) { ForEach(0..<6) { Text(labels[$0]).tag($0) } }.labelsHidden()
                    Button { nudge(dx: -0.003, dy: 0) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("선택한 점 왼쪽 이동")
                    Button { nudge(dx: 0.003, dy: 0) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("선택한 점 오른쪽 이동")
                    Button { nudge(dx: 0, dy: 0.003) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("선택한 점 위로 이동")
                    Button { nudge(dx: 0, dy: -0.003) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("선택한 점 아래로 이동")
                }.buttonStyle(.bordered)
                Text("초록 점은 바깥 모서리, 주황 점은 접힘선 양끝입니다. 원본은 보존됩니다.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if library.busy { ProgressView(library.progress).padding(.bottom, 8) }
            }.disabled(library.busy).navigationTitle("양쪽 페이지 경계 확인").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("나중에") { dismiss() }.disabled(library.busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(record.isPending ? "두 페이지 저장" : "변경 저장") { Task { if await library.saveReviewed(record) { dismiss() } } }
                            .disabled(image == nil || !record.geometry.isValid || library.busy).accessibilityIdentifier("saveSpread")
                    }
                }
        }.interactiveDismissDisabled(library.busy)
            .task {
                do {
                    let data = try await library.storage.source(record)
                    image = await Task.detached {
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil as UIImage? }
                        return UIImage(cgImage: cg)
                    }.value
                    if image == nil { loadError = "이미지 형식을 읽을 수 없습니다." }
                } catch { loadError = error.localizedDescription }
            }
            .alert("저장하지 못했습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("확인") { library.error = nil } } message: { Text(library.error ?? "") }
    }

    private func screenPoints(_ rect: CGRect) -> [CGPoint] {
        record.geometry.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
    }
    private func nudge(dx: CGFloat, dy: CGFloat) {
        let point = record.geometry.points[selectedHandle]
        record.geometry.points[selectedHandle] = CGPoint(x: min(1, max(0, point.x + dx)), y: min(1, max(0, point.y + dy)))
    }
}
