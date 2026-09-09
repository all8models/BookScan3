import Foundation
import Network
import Darwin

enum TransferRoute: Equatable {
    case landing, pdf, rejected
    static func parse(_ header: String, token: String) -> TransferRoute {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .rejected }
        let fields = first.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET", fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0",
              let components = URLComponents(string: String(fields[1])), components.scheme == nil, components.host == nil,
              components.queryItems?.first(where: { $0.name == "token" })?.value == token else { return .rejected }
        switch components.path { case "/": return .landing; case "/download.pdf": return .pdf; default: return .rejected }
    }
}

final class PCTransferServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bookscan.transfer")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var handles: [UUID: FileHandle] = [:]
    private var running = false
    private var token = ""
    var onStatus: (@Sendable (String?, String?) -> Void)?

    func start(file: URL) {
        queue.async {
            self.stopOnQueue()
            guard let address = Self.wifiAddress() else { self.onStatus?(nil, "Wi-Fi에 연결한 뒤 다시 시도해 주세요."); return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .wifi
                parameters.includePeerToPeer = false
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                self.running = true
                self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let token = self.token
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.running else { return }
                    switch state {
                    case .ready:
                        if let port = listener?.port { self.onStatus?("http://\(address):\(port.rawValue)/?token=\(token)", nil) }
                    case .failed(let error): self.onStatus?(nil, error.localizedDescription); self.stopOnQueue()
                    default: break
                    }
                }
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
    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        running = false; listener?.cancel(); listener = nil
        for id in Array(connections.keys) { close(id) }
        token = ""
    }
    private func close(_ id: UUID) {
        try? handles.removeValue(forKey: id)?.close()
        connections.removeValue(forKey: id)?.cancel()
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data, file: URL, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.running, self.connections[id] != nil else { return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard error == nil, buffer.count <= 8192 else { self.close(id); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                let route = TransferRoute.parse(String(decoding: buffer, as: UTF8.self), token: token)
                switch route {
                case .landing:
                    let html = """
                    <!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>BookScan3</title><style>body{background:#f6f4ee;color:#244c3e;font:18px system-ui;max-width:560px;margin:15vh auto;padding:32px}a{display:inline-block;background:#285b46;color:white;padding:16px 28px;border-radius:12px;text-decoration:none}p{line-height:1.7}</style><h1>나의 책, 이제 PC에서도.</h1><p>iPad에서 선택한 책이 준비되었습니다.<br>전송이 끝날 때까지 iPad의 전송 화면을 열어 두세요.</p><a href="/download.pdf?token=\(token)">PDF 다운로드</a><p><small>BookScan3 · 로컬 Wi-Fi 전송</small></p></html>
                    """
                    self.respond(connection, id: id, body: Data(html.utf8), type: "text/html; charset=utf-8")
                case .pdf: self.sendFile(connection, id: id, file: file)
                case .rejected: self.respond(connection, id: id, body: Data("접속 주소를 확인해 주세요.".utf8), type: "text/plain; charset=utf-8", status: "403 Forbidden")
                }
            } else if complete { self.close(id) }
            else { self.read(connection, id: id, buffer: buffer, file: file, token: token) }
        }
    }
    private func header(length: UInt64, type: String, status: String = "200 OK", attachment: Bool = false) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n\(attachment ? "Content-Disposition: attachment; filename=BookScan.pdf\r\n" : "")\r\n".utf8)
    }
    private func respond(_ connection: NWConnection, id: UUID, body: Data, type: String, status: String = "200 OK") {
        connection.send(content: header(length: UInt64(body.count), type: type, status: status) + body, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
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
    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer = interfaces
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: current.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
