import Darwin
import Foundation

/// A blocking Unix-domain stream socket with length-prefixed frame helpers.
///
/// Reads happen on a dedicated task in `DirectorClient`; writes are serialized
/// by a lock. The socket is `@unchecked Sendable` because all mutable state is
/// guarded by locks and the file descriptor is only closed once.
public final class UnixSocket: @unchecked Sendable {
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var fileDescriptor: Int32
    private var closed = false

    public let path: String

    private init(fileDescriptor: Int32, path: String) {
        self.fileDescriptor = fileDescriptor
        self.path = path
    }

    deinit {
        close()
    }

    public static func connect(path: String) throws -> UnixSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathLength = path.utf8.count
        guard pathLength <= DirectorProtocol.maxSocketPathBytes else {
            throw DirectorError.socketPathTooLong(pathLength)
        }

        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw DirectorError.socketPathTooLong(pathLength)
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DirectorError.connectFailed(
                path: path,
                code: errno,
                message: String(cString: strerror(errno))
            )
        }

        var noSignal: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    descriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }

        guard result == 0 else {
            let code = errno
            let message = String(cString: strerror(code))
            Darwin.close(descriptor)
            throw DirectorError.connectFailed(path: path, code: code, message: message)
        }

        return UnixSocket(fileDescriptor: descriptor, path: path)
    }

    /// Reads one complete frame and returns its JSON payload.
    public func readFrame() throws -> Data {
        let header = try readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        guard length > 0 else {
            throw DirectorError.invalidFrame("empty frames are not valid protocol messages")
        }
        guard Int(length) <= DirectorProtocol.maxPayloadBytes else {
            throw DirectorError.frameTooLarge(Int(length) + 4)
        }

        return try readExactly(Int(length))
    }

    public func writeFrame(_ payload: Data) throws {
        guard payload.count <= DirectorProtocol.maxPayloadBytes else {
            throw DirectorError.frameTooLarge(payload.count + 4)
        }

        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeAll(frame)
    }

    public func close() {
        writeLock.lock()
        stateLock.lock()
        let descriptor = fileDescriptor
        let alreadyClosed = closed
        closed = true
        fileDescriptor = -1
        stateLock.unlock()
        writeLock.unlock()

        if !alreadyClosed, descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func currentDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, fileDescriptor >= 0 else {
            throw DirectorError.socketClosed
        }
        return fileDescriptor
    }

    private func readExactly(_ count: Int) throws -> Data {
        let descriptor = try currentDescriptor()
        var data = Data(count: count)
        var offset = 0

        while offset < count {
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
            }

            if bytesRead == 0 {
                throw DirectorError.socketClosed
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw DirectorError.invalidFrame(
                    "socket read failed: \(String(cString: strerror(errno)))"
                )
            }
            offset += bytesRead
        }

        return data
    }

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        let descriptor = try currentDescriptor()
        var offset = 0

        while offset < data.count {
            let bytesWritten = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
            }

            if bytesWritten < 0 {
                if errno == EINTR { continue }
                throw DirectorError.invalidFrame(
                    "socket write failed: \(String(cString: strerror(errno)))"
                )
            }
            if bytesWritten == 0 {
                throw DirectorError.socketClosed
            }
            offset += bytesWritten
        }
    }
}
