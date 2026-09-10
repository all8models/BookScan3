import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct BookDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let bookID: UUID
    @State private var scanning = false
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
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("MY COLLECTION").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(Theme.accent)
                                Text(book.title).font(.system(size: 36, weight: .semibold, design: .serif))
                                Text("\(book.pages.count)페이지  ·  \(book.updatedAt.formatted(date: .abbreviated, time: .shortened)) 수정").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "book.closed").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Theme.accent).padding(18).background(Theme.paper, in: RoundedRectangle(cornerRadius: 18))
                        }
                        HStack(spacing: 12) {
                            Button("스캔 시작", systemImage: "camera") { scanning = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("startScan")
                            PhotosPicker(selection: $photos, maxSelectionCount: 50, matching: .images) { Label("사진 가져오기", systemImage: "photo.on.rectangle") }.buttonStyle(.bordered)
                        }.controlSize(.large).disabled(library.busy)
                        if library.busy { HStack { ProgressView(); Text(library.progress.isEmpty ? "저장 중…" : library.progress).font(.subheadline) } }
                        ForEach(library.drafts.filter { $0.bookID == bookID }) { draft in
                            HStack {
                                Label("경계 확인이 필요한 촬영", systemImage: "viewfinder")
                                Spacer()
                                Button("계속 편집") { review = draft }.accessibilityIdentifier("resumeSpread")
                                Button("삭제", role: .destructive) { discarding = draft }
                            }.padding().background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)).disabled(library.busy)
                        }
                        Divider()
                        HStack { Text("페이지").font(.title3.bold()); Spacer(); Text("길게 눌러 순서를 바꾸세요").font(.caption).foregroundStyle(.secondary) }
                        if book.pages.isEmpty {
                            ContentUnavailableView("아직 스캔한 페이지가 없어요", systemImage: "doc.viewfinder", description: Text("카메라로 책을 촬영하거나 사진을 가져오세요.")).frame(minHeight: 280)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 22)], spacing: 26) {
                                ForEach(Array(book.pages.enumerated()), id: \.element.id) { index, page in
                                    Button { selectedPage = page } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            PageThumbnail(url: library.root.appending(path: page.thumbnailName))
                                                .frame(height: 215).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 8)).clipped().shadow(color: .black.opacity(0.07), radius: 8, y: 3)
                                            HStack { Text(String(format: "%02d", index + 1)).font(.subheadline.monospacedDigit()); Spacer(); if !page.text.isEmpty { Image(systemName: "text.viewfinder").foregroundStyle(Theme.accent) } }
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
                            }
                        }
                    }.padding(32)
                }.background(Theme.paper.opacity(0.4))
                .navigationTitle("책 상세").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
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
        .fullScreenCover(isPresented: $scanning) { CameraScannerView(bookID: bookID).environmentObject(library) }
        .sheet(item: $selectedPage) { page in PageDetailView(bookID: bookID, pageID: page.id).environmentObject(library) }
        .sheet(item: $shared) { item in ShareSheet(items: [item.url]) }
        .sheet(item: $transfer) { item in PCTransferView(url: item.url) }
        .sheet(item: $review) { record in SpreadReviewView(record: record).environmentObject(library) }
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
