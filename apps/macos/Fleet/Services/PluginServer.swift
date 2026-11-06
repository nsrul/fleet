import Darwin
import FleetAPI
import Foundation

enum PluginServerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

/// Loopback MCP server. The bearer token is the URL path. Nothing here is logged.
final class PluginServer: @unchecked Sendable {
    let token: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var handler: PluginHandler?
    private var configURLs: [URL] = []
    private var endpoint: FleetPluginEndpoint?

    init(token: String) {
        self.token = token
    }

    static func newToken() -> String {
        let first = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let second = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return first + second
    }

    func currentEndpoint() -> FleetPluginEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoint
    }

    @discardableResult
    func start(handler makeHandler: (FleetPluginEndpoint) -> PluginHandler) throws -> FleetPluginEndpoint {
        stop()
        let fd = try Self.bindLoopback()
        do {
            let port = try Self.boundPort(fd)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fleet-plugin-\(getuid())", isDirectory: true)
            let url = "http://127.0.0.1:\(port)/mcp/\(token)"
            let claudeConfig = try FleetPluginFiles.writeClaudeConfig(url: url, directory: directory)
            let geminiSettings = try? FleetPluginFiles.writeGeminiSettings(
                url: url,
                directory: directory,
                systemSettings: FleetPluginFiles.geminiSystemSettingsPath(
                    environment: ProcessInfo.processInfo.environment
                )
            )
            let endpoint = FleetPluginEndpoint(
                url: url,
                claudeConfigPath: claudeConfig.path,
                geminiSettingsPath: geminiSettings?.path,
                opencodeConfig: FleetPluginFiles.opencodeConfig(url: url)
            )
            let handler = makeHandler(endpoint)
            lock.lock()
            listenFD = fd
            self.handler = handler
            configURLs = [claudeConfig] + [geminiSettings].compactMap { $0 }
            self.endpoint = endpoint
            lock.unlock()
        } catch {
            close(fd)
            throw error
        }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            let fd = self.currentListenFD()
            guard fd >= 0 else { return }
            self.acceptLoop(fd)
        }
        lock.lock()
        acceptTask = task
        lock.unlock()
        guard let endpoint = currentEndpoint() else {
            throw PluginServerError.message("The plugin server did not start.")
        }
        return endpoint
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        let task = acceptTask
        acceptTask = nil
        handler = nil
        let config = configURLs
        configURLs = []
        endpoint = nil
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        task?.cancel()
        FleetPluginFiles.remove(config)
    }

    private func currentListenFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listenFD
    }

    private func currentHandler() -> PluginHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private func acceptLoop(_ fd: Int32) {
        while !Task.isCancelled {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &address, &length)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let handler = currentHandler()
            let token = self.token
            Task.detached {
                await Self.exchange(fd: client, token: token, handler: handler)
                close(client)
            }
        }
    }

    private static func bindLoopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PluginServerError.message("Could not open the plugin socket.")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fd)
            throw PluginServerError.message("Could not bind the plugin server.")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw PluginServerError.message("Could not listen for plugin clients.")
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &length)
            }
        }
        guard result == 0 else {
            throw PluginServerError.message("Could not read the plugin port.")
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func exchange(fd: Int32, token: String, handler: PluginHandler?) async {
        guard let request = readRequest(fd) else {
            write(fd, status: 400, reason: "Bad Request", body: Data("{\"error\":\"bad request\"}".utf8))
            return
        }
        guard request.method == "POST" else {
            write(fd, status: 405, reason: "Method Not Allowed", body: Data())
            return
        }
        guard tokensMatch(request.path, token: token) else {
            write(fd, status: 404, reason: "Not Found", body: Data())
            return
        }
        guard let handler else {
            write(fd, status: 503, reason: "Service Unavailable", body: Data())
            return
        }
        if let response = await PluginRPC.respond(to: request.body, handler: handler) {
            write(fd, status: 200, reason: "OK", body: response)
        } else {
            write(fd, status: 202, reason: "Accepted", body: Data())
        }
    }

    private struct Request {
        var method: String
        var path: String
        var body: Data
    }

    private static func readRequest(_ fd: Int32) -> Request? {
        let headerLimit = 65_536
        let bodyLimit = 1_048_576
        var buffer = Data()
        guard readUntilHeader(fd, into: &buffer, limit: headerLimit) else { return nil }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: head, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let value = Int(pair[1].trimmingCharacters(in: .whitespaces)) {
                length = value
            }
        }
        guard length >= 0, length <= bodyLimit else { return nil }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard readChunk(fd, into: &body, limit: headerLimit + length) else { return nil }
        }
        if body.count > length {
            body = body.prefix(length)
        }
        return Request(method: method, path: path, body: body)
    }

    private static func readUntilHeader(_ fd: Int32, into buffer: inout Data, limit: Int) -> Bool {
        let marker = Data("\r\n\r\n".utf8)
        while buffer.range(of: marker) == nil {
            if buffer.count >= limit { return false }
            if !readChunk(fd, into: &buffer, limit: limit) { return false }
        }
        return true
    }

    private static func readChunk(_ fd: Int32, into buffer: inout Data, limit: Int) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8_192)
        let count = chunk.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        guard count > 0 else { return false }
        if buffer.count + count > limit { return false }
        buffer.append(contentsOf: chunk.prefix(count))
        return true
    }

    private static func tokensMatch(_ path: String, token: String) -> Bool {
        let prefix = "/mcp/"
        guard path.hasPrefix(prefix), path.count == prefix.count + token.count else { return false }
        let presented = path.dropFirst(prefix.count)
        let left = Array(presented.utf8)
        let right = Array(token.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }

    private static func write(_ fd: Int32, status: Int, reason: String, body: Data) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
