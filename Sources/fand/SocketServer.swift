import Foundation
import FanKit

/// Unix-domain socket server speaking line-delimited JSON.
///
/// One request per connection: read a line, answer with a line, close. The UI
/// polls at 1 Hz, which this handles comfortably and keeps the protocol
/// debuggable with `nc -U`.
final class SocketServer {

    private let path: String
    private let handler: (Request) -> Response
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "fand.accept")
    private let workQueue = DispatchQueue(label: "fand.work", attributes: .concurrent)

    init(path: String, handler: @escaping (Request) -> Response) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= capacity else {
            throw NSError(domain: "SocketServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "socket path too long (\(pathBytes.count) > \(capacity))"
            ])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bindResult == 0 else { close(listenFD); throw posixError("bind") }
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw posixError("listen") }

        // The daemon runs as root; the UI does not. Let any local user connect.
        chmod(path, 0o666)

        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if running && errno != EINTR {
                    FileHandle.standardError.write("accept failed: \(String(cString: strerror(errno)))\n"
                        .data(using: .utf8)!)
                }
                continue
            }
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in self?.serve(clientFD) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        guard let line = readLine(fd), !line.isEmpty else { return }

        let response: Response
        if let data = line.data(using: .utf8),
           let request = try? IPC.decoder().decode(Request.self, from: data) {
            response = handler(request)
        } else {
            response = .failure("malformed request")
        }

        guard var payload = try? IPC.encoder().encode(response) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// Reads until newline. Caps the request size so a stuck client can't
    /// balloon the daemon's memory.
    private func readLine(_ fd: Int32, limit: Int = 1 << 20) -> String? {
        var accumulated = Data()
        var byte: UInt8 = 0
        while accumulated.count < limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            accumulated.append(byte)
        }
        return String(data: accumulated, encoding: .utf8)
    }

    private func posixError(_ op: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(errno)))"
        ])
    }
}
