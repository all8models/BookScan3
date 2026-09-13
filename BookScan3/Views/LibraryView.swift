import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @State private var search = ""
    @State private var creating = false
    @State private var title = ""
    @State private var deleting: Book?
    @State private var path: [UUID] = []
    @State private var recentVisible = true
    @State private var newest = true
    @State private var scanning = false
    @State private var transfer: SharedFile?
    @State private var recentPage: RecentPage?
    private struct RecentPage: Identifiable { let bookID: UUID; let page: ScanPage; var id: UUID { page.id } }
    private var filtered: [Book] {
        library.search(query: search)
            .sorted { newest ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt }
    }
    private var recent: [RecentPage] {
        Array(library.books.flatMap { book in book.pages.map { RecentPage(bookID: book.id, page: $0) } }.sorted { $0.page.createdAt > $1.page.createdAt }.prefix(20))
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Menu {
                        ForEach(library.books.filter { !$0.pages.isEmpty }) { book in
                            Button(book.title) { Task { if let url = await library.export(book) { transfer = SharedFile(url: url) } } }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("PC로 Wi-Fi 전송", systemImage: "desktopcomputer").font(.headline)
                                Text("책을 선택해 PDF를 전송하세요").font(.subheadline)
                            }
                            Spacer(); Image(systemName: "chevron.right")
                        }.foregroundStyle(.primary).padding(22).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    }.disabled(library.busy || library.books.allSatisfy { $0.pages.isEmpty })
                    Button { recentVisible.toggle() } label: {
                        HStack { Text("최근 스캔"); Spacer(); Text(recentVisible ? "접기" : "펼치기"); Image(systemName: recentVisible ? "chevron.up" : "chevron.down") }.foregroundStyle(.secondary)
                    }
                    if recentVisible {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(recent) { item in
                                    Button { recentPage = item } label: {
                                        PageThumbnail(url: library.root.appending(path: item.page.thumbnailName)).frame(width: 112, height: 120).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 6))
                                    }.accessibilityLabel("최근 페이지 보기")
                                }
                            }
                        }
                        if recent.isEmpty { Text("촬영한 페이지가 여기에 표시됩니다").foregroundStyle(.secondary) }
                    }
                    HStack { Text("책 (\(filtered.count))"); Spacer(); Button(newest ? "수정일 ↓" : "수정일 ↑") { newest.toggle() } }.foregroundStyle(.secondary)
                    LazyVStack(spacing: 18) {
                        ForEach(filtered) { book in
                            NavigationLink(value: book.id) {
                                HStack(spacing: 20) {
                                    if let page = book.pages.first {
                                        PageThumbnail(url: library.root.appending(path: page.thumbnailName)).frame(width: 112, height: 132).clipped()
                                    } else { Image(systemName: "book.closed").font(.largeTitle).frame(width: 112, height: 132).background(Color(.secondarySystemBackground)) }
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(book.title).font(.title3.bold()).foregroundStyle(.primary)
                                        Text("\(book.updatedAt.formatted(date: .numeric, time: .shortened)) · \(book.pages.count)페이지").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("bookRow-" + book.title).contextMenu { Button("책 삭제", role: .destructive) { deleting = book } }
                        }
                    }
                    if library.books.isEmpty { ContentUnavailableView("서재가 비어 있어요", systemImage: "books.vertical", description: Text("아래 + 버튼으로 첫 책을 만드세요.")) }
                }.padding(24).padding(.bottom, 80)
            }.background(Theme.paper).navigationTitle("서재").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "책 제목 또는 인식한 텍스트")
                .navigationDestination(for: UUID.self) { id in BookDetailView(bookID: id).onAppear { library.selectedID = id } }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("카메라", systemImage: "camera") {
                            if library.selected == nil { library.selectedID = library.books.first?.id }
                            if library.selected != nil { scanning = true } else { creating = true }
                        }.disabled(!library.loaded || library.busy)
                    }
                    ToolbarItem(placement: .topBarTrailing) { Menu { Button("새 책 만들기") { title = ""; creating = true }; Button("서재 다시 불러오기") { Task { await library.load() } } } label: { Image(systemName: "ellipsis.circle") } }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button { title = ""; creating = true } label: { Image(systemName: "folder.badge.plus").font(.title).foregroundStyle(.white).padding(22).background(Theme.accent, in: RoundedRectangle(cornerRadius: 22)) }
                        .accessibilityLabel("새 책 만들기").accessibilityIdentifier("createBook").disabled(!library.loaded || library.busy).padding(24)
                }
        }
        .fullScreenCover(isPresented: $scanning) { if let id = library.selectedID { CameraScannerView(bookID: id) } }
        .fullScreenCover(item: $recentPage) { item in PageDetailView(bookID: item.bookID, pageID: item.page.id) }
        .sheet(item: $transfer) { item in PCTransferView(url: item.url) }
        .alert("새 책", isPresented: $creating) {
            TextField("책 제목", text: $title)
            Button("취소", role: .cancel) { }
            Button("만들기") { Task { await library.create(title: title); if let id = library.selectedID { path.append(id) } } }
        }
        .alert("책을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) { if let book = deleting { Task { await library.delete(book) } }; deleting = nil }
        } message: { Text("이 책의 모든 페이지가 기기에서 삭제됩니다.") }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("확인") { library.error = nil } } message: { Text(library.error ?? "") }
    }
}
