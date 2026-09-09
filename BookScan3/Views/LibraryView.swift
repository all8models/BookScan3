import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @State private var search = ""
    @State private var creating = false
    @State private var title = ""
    @State private var deleting: Book?
    private var filtered: [Book] {
        library.books.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.pages.contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("BOOKSCAN 3", systemImage: "book.closed.fill").font(.headline).tracking(2)
                    Text("종이의 기록을,\n나의 서재로.").font(.system(size: 29, weight: .semibold, design: .serif))
                }.padding(.horizontal, 22).padding(.top, 20)
                Button { title = ""; creating = true } label: {
                    Label("새 책 만들기", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).padding(.horizontal, 20).disabled(!library.loaded || library.busy).accessibilityIdentifier("createBook")
                List(selection: $library.selectedID) {
                    Section("내 서재 · \(library.books.count)") {
                        ForEach(filtered) { book in
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed").font(.title3).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(book.title).font(.headline).lineLimit(1)
                                    Text("\(book.pages.count)페이지 · \(book.updatedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6).tag(book.id)
                                .contextMenu { Button("책 삭제", role: .destructive) { deleting = book }.disabled(library.busy) }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                Label("모든 스캔은 이 기기에 저장됩니다", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(20)
            }.background(Theme.paper).navigationTitle("서재").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "책 제목 또는 인식한 텍스트")
        } detail: {
            if let book = library.selected { BookDetailView(bookID: book.id).id(book.id) }
            else {
                VStack(spacing: 24) {
                    Image(systemName: "books.vertical").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(Theme.accent)
                    Text("한 페이지부터 시작하는\n나만의 디지털 서재").font(.system(size: 34, weight: .medium, design: .serif)).multilineTextAlignment(.center)
                    Text("책을 만들고, 펼치고, 스캔하세요.\n텍스트 인식부터 PDF 공유까지 이곳에서.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("첫 책 만들기", systemImage: "plus") { title = ""; creating = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!library.loaded || library.busy)
                    if !library.loaded { Button("서재 다시 불러오기") { Task { await library.load() } } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paper.opacity(0.55))
            }
        }
        .alert("새 책", isPresented: $creating) {
            TextField("책 제목", text: $title)
            Button("취소", role: .cancel) { }
            Button("만들기") { Task { await library.create(title: title) } }
        } message: { Text("스캔할 책의 제목을 입력해 주세요.") }
        .alert("책을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) { if let book = deleting { Task { await library.delete(book) } }; deleting = nil }
        } message: { Text("이 책의 모든 페이지가 기기에서 삭제됩니다.") }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("확인") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}
