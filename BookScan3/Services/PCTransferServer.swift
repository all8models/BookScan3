import Foundation
import Network
import Darwin

/// PC 전송 요청 경로 구분.
enum TransferRoute: Equatable {
    case landing   // 메인 랜딩 페이지 ("/")
    case pdf       // PDF 다운로드 ("/download.pdf")
    case rejected  // 잘못된 요청 또는 토큰 불일치

    /// HTTP 요청 헤더와 쿼리 토큰을 파싱하여 라우트를 결정합니다.
    static func parse(_ header: String, token: String) -> TransferRoute {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .rejected }
        let fields = first.split(separator: " ")
        // 메서드(GET/HEAD), HTTP 버전, 경로 탐색(..) 방지 및 토큰 일치 여부 검증
        guard fields.count == 3,
              fields[0] == "GET" || fields[0] == "HEAD",
              fields[2].hasPrefix("HTTP/"),
              let components = URLComponents(string: String(fields[1])),
              components.scheme == nil, components.host == nil,
              !components.path.contains(".."),
              components.queryItems?.first(where: { $0.name == "token" })?.value == token else { return .rejected }
        switch components.path {
        case "/": return .landing
        case "/download.pdf": return .pdf
        default: return .rejected
        }
    }
}

/// 동일 로컬 Wi-Fi 서브넷 상의 PC 웹 브라우저로 스캔 도서 PDF를 전송하는 초경량 HTTP 서버.
final class PCTransferServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bookscan.transfer")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var handles: [UUID: FileHandle] = [:]
    private var running = false
    private var token = ""
    /// UI에 서버 URL 또는 에러 메시지를 전달하는 콜백
    var onStatus: (@Sendable (String?, String?) -> Void)?

    /// 지정된 PDF 파일에 대해 전송 서버를 시작합니다.
    func start(file: URL) {
        // [self]를 명시적으로 캡처하여 내부 비동기 이벤트 핸들러의 [weak self]와의 소유권 불일치 경고를 방지합니다.
        queue.async { [self] in
            self.stopOnQueue()
            // Wi-Fi IPv4 주소 조회
            guard let address = Self.wifiAddress() else { self.onStatus?(nil, "Wi-Fi에 연결한 뒤 다시 시도해 주세요."); return }
            do {
                // Wi-Fi 인터페이스 한정 TCP 파라미터 구성
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .wifi
                parameters.includePeerToPeer = false
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                self.running = true
                // 세션별 일회용 보안 토큰 생성
                self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let token = self.token
                
                // 리스너 상태 변화 핸들러 (준비 완료 시 접속 URL 알림)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.running else { return }
                    switch state {
                    case .ready:
                        if let port = listener?.port { self.onStatus?("http://\(address):\(port.rawValue)/?token=\(token)", nil) }
                    case .failed(let error): self.onStatus?(nil, error.localizedDescription); self.stopOnQueue()
                    default: break
                    }
                }
                
                // 신규 클라이언트 접속 핸들러 (최대 4개 동시 연결 허용, 120초 자동 타임아웃)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.running, self.connections.count < 4 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.read(connection, id: id, buffer: Data(), file: file, token: token)
                    self.queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close(id) }
                }
                listener.start(queue: self.queue)
            } catch { self.onStatus?(nil, error.localizedDescription) }
        }
    }

    /// 전송 서버를 중지하고 모든 연결을 폐쇄합니다.
    func stop() { queue.async { self.stopOnQueue() } }

    /// 전용 큐 상에서 리스너 및 모든 활성 클라이언트 연결을 정리합니다.
    private func stopOnQueue() {
        running = false; listener?.cancel(); listener = nil
        for id in Array(connections.keys) { close(id) }
        token = ""
    }

    /// 특정 클라이언트 연결 및 열려있는 파일 핸들을 닫습니다.
    private func close(_ id: UUID) {
        try? handles.removeValue(forKey: id)?.close()
        connections.removeValue(forKey: id)?.cancel()
    }

    /// 클라이언트로부터 HTTP 요청 데이터를 수신하여 라우팅 처리합니다.
    private func read(_ connection: NWConnection, id: UUID, buffer: Data, file: URL, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.running, self.connections[id] != nil else { return }
            var buffer = buffer; buffer.append(data ?? Data())
            // 요청 헤더가 너무 길어지면 버퍼 오버플로우 방지를 위해 연결 차단 (최대 8KB)
            guard error == nil, buffer.count <= 8192 else { self.close(id); return }
            
            // HTTP 헤더의 끝(\r\n\r\n)이 수신된 경우 요청 파싱
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                let route = TransferRoute.parse(String(decoding: buffer, as: UTF8.self), token: token)
                switch route {
                case .landing:
                    // 브라우저 접속 시 표시할 안내 랜딩 페이지 HTML
                    let html = """
                    <!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>BookScan3</title><style>body{background:#f6f4ee;color:#244c3e;font:18px system-ui;max-width:560px;margin:15vh auto;padding:32px}a{display:inline-block;background:#285b46;color:white;padding:16px 28px;border-radius:12px;text-decoration:none}p{line-height:1.7}</style><h1>나의 책, 이제 PC에서도.</h1><p>iPad에서 선택한 책이 준비되었습니다.<br>전송이 끝날 때까지 iPad의 전송 화면을 열어 두세요.</p><a href="/download.pdf?token=\(token)">PDF 다운로드</a><p><small>BookScan3 · 로컬 Wi-Fi 전송</small></p></html>
                    """
                    self.respond(connection, id: id, body: Data(html.utf8), type: "text/html; charset=utf-8")
                case .pdf:
                    // PDF 파일 스트리밍 전송
                    self.sendFile(connection, id: id, file: file)
                case .rejected:
                    // 유효하지 않은 주소 또는 토큰
                    self.respond(connection, id: id, body: Data("접속 주소를 확인해 주세요.".utf8), type: "text/plain; charset=utf-8", status: "403 Forbidden")
                }
            } else if complete { self.close(id) }
            else { self.read(connection, id: id, buffer: buffer, file: file, token: token) }
        }
    }

    /// 표준 보안 및 캐시 제어 헤더가 포함된 HTTP 응답 헤더 바이너리를 생성합니다.
    private func header(length: UInt64, type: String, status: String = "200 OK", attachment: Bool = false) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n\(attachment ? "Content-Disposition: attachment; filename=BookScan.pdf\r\n" : "")\r\n".utf8)
    }

    /// 단일 HTTP 응답을 전송한 후 연결을 종료합니다.
    private func respond(_ connection: NWConnection, id: UUID, body: Data, type: String, status: String = "200 OK") {
        connection.send(content: header(length: UInt64(body.count), type: type, status: status) + body, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    /// 대용량 PDF 파일 전송을 위해 FileHandle을 열고 헤더를 전송합니다.
    private func sendFile(_ connection: NWConnection, id: UUID, file: URL) {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            let length = try handle.seekToEnd(); try handle.seek(toOffset: 0)
            handles[id] = handle
            connection.send(content: header(length: length, type: "application/pdf", attachment: true), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error == nil { self.sendChunk(connection, id: id) } else { self.close(id) }
            })
        } catch { respond(connection, id: id, body: Data("파일을 읽을 수 없습니다.".utf8), type: "text/plain; charset=utf-8", status: "500 Internal Server Error") }
    }

    /// 메모리 사용량을 최소화하기 위해 64KB 단위로 청크 분할 전송합니다.
    private func sendChunk(_ connection: NWConnection, id: UUID) {
        guard running, let handle = handles[id] else { close(id); return }
        do {
            guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { close(id); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error == nil { self.sendChunk(connection, id: id) } else { self.close(id) }
            })
        } catch { close(id) }
    }

    /// 시스템 네트워크 인터페이스 목록에서 활성화된 로컬 Wi-Fi IPv4 주소를 탐색합니다.
    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer = interfaces
        var candidates: [(name: String, ip: String)] = []
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") { candidates.append((name, ip)) }
            }
        }
        if let en0 = candidates.first(where: { $0.name == "en0" })?.ip { return en0 }
        if let en = candidates.first(where: { $0.name.hasPrefix("en") })?.ip { return en }
        if let other = candidates.first(where: { $0.name.hasPrefix("bridge") || $0.name.hasPrefix("pdp_ip") })?.ip { return other }
        return candidates.first?.ip
    }
}

