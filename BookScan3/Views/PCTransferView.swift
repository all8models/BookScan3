import SwiftUI

@MainActor
final class TransferViewModel: ObservableObject {
    @Published var address: String?
    @Published var error: String?
    private let server = PCTransferServer()
    init() { server.onStatus = { [weak self] address, error in Task { @MainActor in self?.address = address; self?.error = error } } }
    func start(_ url: URL) { address = nil; error = nil; server.start(file: url) }
    func stop() { server.stop(); address = nil }
}

struct PCTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = TransferViewModel()
    let url: URL
    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                Image(systemName: "wifi").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.accent)
                Text("책을 PC로 옮기세요").font(.title.bold())
                Text("같은 Wi-Fi에 연결한 PC의 브라우저에\n아래 주소를 입력하세요.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let address = model.address {
                    Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(20).background(Theme.paper, in: RoundedRectangle(cornerRadius: 14))
                    Button("주소 복사", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }.buttonStyle(.borderedProminent)
                } else if let error = model.error { Text(error).foregroundStyle(.secondary); Button("다시 연결") { model.start(url) } }
                else { ProgressView("전송 준비 중…") }
                Text("이 주소를 아는 같은 Wi-Fi의 기기에서 PDF를 받을 수 있습니다.\n화면을 닫거나 앱을 벗어나면 전송이 중지됩니다.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(32).navigationTitle("Wi-Fi 전송").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.onAppear { model.start(url); UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { model.stop(); UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of: phase) { _, phase in if phase == .active { model.start(url); UIApplication.shared.isIdleTimerDisabled = true } else { model.stop(); UIApplication.shared.isIdleTimerDisabled = false } }
    }
}
