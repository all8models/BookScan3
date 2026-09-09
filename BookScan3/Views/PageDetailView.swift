import SwiftUI
import AVFoundation

@MainActor
final class SpeechService: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

struct PageDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @State private var textMode = false
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    let bookID: UUID
    let pageID: UUID
    var page: ScanPage? { library.books.first { $0.id == bookID }?.pages.first { $0.id == pageID } }
    var body: some View {
        NavigationStack {
            if let page {
                VStack(spacing: 0) {
                    Picker("보기", selection: $textMode) { Text("스캔 이미지").tag(false); Text("인식한 텍스트").tag(true) }.pickerStyle(.segmented).padding()
                    if textMode {
                        if page.text.isEmpty { ContentUnavailableView("인식한 텍스트가 없어요", systemImage: "text.viewfinder", description: Text("텍스트 인식을 눌러 이 페이지를 읽어 보세요.")) }
                        else { ScrollView { Text(page.text).font(.body).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) } }
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            PageThumbnail(url: library.root.appending(path: page.imageName)).frame(width: 560 * min(4, max(1, scale * magnification)), height: 740 * min(4, max(1, scale * magnification))).padding(20)
                        }.defaultScrollAnchor(.center)
                            .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { scale = min(4, max(1, scale * $0.magnification)) })
                    }
                    if library.busy { ProgressView(library.progress.isEmpty ? "처리 중…" : library.progress).padding() }
                    HStack {
                        Menu { ForEach(ScanFilter.allCases) { filter in Button(filter.title) { Task { await library.apply(filter: filter, pageID: pageID, bookID: bookID) } } } } label: { Label(page.filter.title, systemImage: "camera.filters") }
                        Spacer()
                        Button("텍스트 인식", systemImage: "text.viewfinder") { Task { await library.recognize(bookID: bookID, pageID: pageID); textMode = true } }
                        Menu {
                            Button("읽어 주기", systemImage: "speaker.wave.2") { speech.speak(page.text) }
                            Button("읽기 중지", systemImage: "stop") { speech.stop() }
                            Button("텍스트 복사", systemImage: "doc.on.doc") { UIPasteboard.general.string = page.text }
                            ShareLink(item: page.text) { Label("텍스트 공유", systemImage: "square.and.arrow.up") }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(page.text.isEmpty)
                    }.padding(20).disabled(library.busy)
                }.background(Theme.paper.opacity(0.5))
                .navigationTitle("페이지 보기").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            }
        }.onDisappear { speech.stop() }
            .alert("처리하지 못했습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("확인") { library.error = nil } } message: { Text(library.error ?? "") }
    }
}
