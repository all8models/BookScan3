import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct BookDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let bookID: UUID
    @State private var scanning = false
    @State private var selecting = false
    @State private var gridWidth: CGFloat = 820
    @Environment(\.dynamicTypeSize) private var typeSize
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: max(1, min(6, Int(gridWidth / (typeSize.isAccessibilitySize ? 220 : 130))))) }
    @State private var selection: Set<UUID> = []
    @State private var confirmSelection = false
    @State private var selectedPage: ScanPage?
    @State private var shared: SharedFile?
    @State private var transfer: SharedFile?
    @State private var photos: [PhotosPickerItem] = []
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting: ScanPage?
    @State private var dragged: UUID?
    @State private var review: CaptureRecord?
    @State private var discarding: CaptureRecord?
    var book: Book? { library.books.first { $0.id == bookID } }
    var body: some View {
        Group {
            if let book {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if library.busy { HStack { ProgressView(); Text(library.progress.isEmpty ? "저장 중…" : library.progress).font(.subheadline) } }
                        ForEach(library.drafts.filter { $0.bookID == bookID }) { draft in
                            HStack {
                                Label("경계 확인이 필요한 촬영", systemImage: "viewfinder")
                                Spacer()
                                Button("계속 편집") { review = draft }.accessibilityIdentifier("resumeSpread")
                                Button("삭제", role: .destructive) { discarding = draft }
                            }.padding().background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)).disabled(library.busy)
                        }

                        if book.pages.isEmpty {
                            ContentUnavailableView("아직 스캔한 페이지가 없어요", systemImage: "doc.viewfinder", description: Text("카메라로 책을 촬영하거나 사진을 가져오세요.")).frame(minHeight: 280)
                            Button("스캔 시작", systemImage: "camera") { scanning = true }.accessibilityIdentifier("startScan").buttonStyle(.borderedProminent)
                        } else {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(Array(book.pages.enumerated()), id: \.element.id) { index, page in
                                    Button { if selecting { if selection.contains(page.id) { selection.remove(page.id) } else { selection.insert(page.id) } } else { selectedPage = page } } label: {
                                        ZStack(alignment: .bottomTrailing) {
                                            PageThumbnail(url: library.root.appending(path: page.thumbnailName))
                                                .frame(height: 185).frame(maxWidth: .infinity).background(.white).clipped()
                                            Text("\(index + 1)").font(.title2).foregroundStyle(.black).padding(3).background(.white.opacity(0.9))
                                            if selecting { Image(systemName: selection.contains(page.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(Theme.accent).padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .contextMenu {
                                            Button("페이지 삭제", role: .destructive) { deleting = page }
                                            Button("앞으로 이동") { move(page.id, offset: -1) }.disabled(index == 0)
                                            Button("뒤로 이동") { move(page.id, offset: 1) }.disabled(index == book.pages.count - 1)
                                        }
                                        .onDrag { dragged = page.id; return NSItemProvider(object: page.id.uuidString as NSString) }
                                        .onDrop(of: [.text], isTargeted: nil) { _ in
                                            guard !library.busy, let source = dragged, let from = book.pages.firstIndex(where: { $0.id == source }), let to = book.pages.firstIndex(where: { $0.id == page.id }) else { return false }
                                            var changed = book; changed.pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                            dragged = nil; Task { await library.update(changed) }; return true
                                        }.disabled(library.busy)
                                }
                                Button { scanning = true } label: { Image(systemName: "camera.badge.ellipsis").font(.largeTitle).frame(maxWidth: .infinity).frame(height: 185).background(Color(.secondarySystemBackground)) }.accessibilityLabel("스캔 시작").accessibilityIdentifier("startScan")
                            }
                        }
                    }.padding(8).padding(.bottom, 90)
                }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .background(Theme.paper.opacity(0.4))
                .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(selecting ? "완료" : "선택") { selecting.toggle(); selection.removeAll() }
                        if selecting { Button("삭제 (\(selection.count))", role: .destructive) { confirmSelection = true }.disabled(selection.isEmpty || library.busy) }
                        Menu {
                            Button("제목 바꾸기", systemImage: "pencil") { title = book.title; renaming = true }
                            Button("전체 텍스트 인식", systemImage: "text.viewfinder") { Task { await library.recognize(bookID: bookID) } }.disabled(book.pages.isEmpty)
                            Button("PC로 Wi-Fi 전송", systemImage: "wifi") { Task { if let url = await library.export(book) { transfer = SharedFile(url: url) } } }.disabled(book.pages.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(library.busy)
                        Button("PDF 내보내기", systemImage: "square.and.arrow.up") { Task { if let url = await library.export(book) { shared = SharedFile(url: url) } } }.disabled(library.busy || book.pages.isEmpty)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                Button("스캔 시작", systemImage: "camera") { scanning = true }
                PhotosPicker(selection: $photos, maxSelectionCount: 50, matching: .images) { Label("사진 가져오기", systemImage: "photo") }
            } label: { Image(systemName: "plus").font(.largeTitle).foregroundStyle(.white).padding(22).background(Theme.accent, in: Circle()) }.disabled(library.busy).padding(24)
        }
        .alert("선택한 \(selection.count)페이지를 삭제할까요?", isPresented: $confirmSelection) {
            Button("취소", role: .cancel) { }
            Button("삭제", role: .destructive) { Task { await library.deletePages(selection, bookID: bookID); selection.removeAll(); selecting = false } }
        } message: { Text("삭제한 페이지는 복원할 수 없습니다.") }
        .fullScreenCover(isPresented: $scanning) { CameraScannerView(bookID: bookID).environmentObject(library) }
        .fullScreenCover(item: $selectedPage) { page in PageDetailView(bookID: bookID, pageID: page.id).environmentObject(library) }
        .sheet(item: $shared) { item in ShareSheet(items: [item.url]) }
        .sheet(item: $transfer) { item in PCTransferView(url: item.url) }
        .fullScreenCover(item: $review) { record in SpreadReviewView(record: record).environmentObject(library) }
        .alert("보관 중인 촬영 원본을 삭제할까요?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("취소", role: .cancel) { discarding = nil }
            Button("삭제", role: .destructive) { if let record = discarding { Task { await library.discardDraft(record) } }; discarding = nil }
        }
        .alert("책 제목", isPresented: $renaming) {
            TextField("제목", text: $title)
            Button("취소", role: .cancel) { }
            Button("저장") { if var book, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.title = title; Task { await library.update(book) } } }
        }
        .alert("페이지를 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) { if var book, let deleting { book.pages.removeAll { $0.id == deleting.id }; Task { await library.update(book); try? await library.storage.removeUnused(library.books) } }; deleting = nil }
        }
        .onChange(of: photos) { _, items in
            Task {
                for item in items {
                    do { if let data = try await item.loadTransferable(type: Data.self) { await library.add(data: data, to: bookID, split: false, spine: nil, filter: .original) } }
                    catch { library.error = error.localizedDescription }
                }
                photos = []
            }
        }
    }
    private func move(_ id: UUID, offset: Int) {
        guard var book, let index = book.pages.firstIndex(where: { $0.id == id }), book.pages.indices.contains(index + offset) else { return }
        book.pages.swapAt(index, index + offset)
        Task { await library.update(book) }
    }
}

struct PageThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary) } }
            .task(id: url) { image = await Task.detached { UIImage(contentsOfFile: url.path) }.value }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
