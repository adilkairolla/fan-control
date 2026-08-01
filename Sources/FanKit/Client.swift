import Foundation

/// Client side of the same protocol, shared by `fanctl` and the UI.
public struct FanControlClient {
    public let socketPath: String

    public init(socketPath: String = IPC.socketPath) {
        self.socketPath = socketPath
    }

    public enum ClientError: Error, CustomStringConvertible {
        case cannotConnect(String)
        case noResponse
        case decodeFailed

        public var description: String {
            switch self {
            case .cannotConnect(let p): return "cannot connect to daemon at \(p) — is fand running?"
            case .noResponse:           return "daemon closed the connection without responding"
            case .decodeFailed:         return "could not decode daemon response"
            }
        }
    }

    public func send(_ request: Request) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.cannotConnect(socketPath) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= capacity else { throw ClientError.cannotConnect(socketPath) }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { throw ClientError.cannotConnect(socketPath) }

        var payload = try IPC.encoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { throw ClientError.noResponse }
                sent += n
            }
        }

        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            accumulated.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        guard !accumulated.isEmpty else { throw ClientError.noResponse }

        if let newline = accumulated.firstIndex(of: 0x0A) {
            accumulated = accumulated[accumulated.startIndex..<newline]
        }
        guard let response = try? IPC.decoder().decode(Response.self, from: accumulated) else {
            throw ClientError.decodeFailed
        }
        return response
    }
}
