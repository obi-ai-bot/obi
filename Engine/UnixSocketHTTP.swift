import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors from the local runner's private Unix socket.
nonisolated struct LocalSocketError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static let timedOut = LocalSocketError(message: "The local runner timed out.")
    static let cancelled = LocalSocketError(message: "The local runner request was cancelled.")
    static let closedEarly = LocalSocketError(message: "The local runner closed its socket early.")
    static let badResponse = LocalSocketError(message: "The local runner returned an invalid HTTP response.")
    static let badHeaders = LocalSocketError(message: "The local runner returned invalid HTTP headers.")
    static let noURL = LocalSocketError(message: "The local runner request has no URL.")
}

/// Resumes a throwing checked continuation at most once. A connection that fails after `.ready`
/// must not resume again; later failures surface through receive callbacks instead.
nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// True when this call performed the resume.
    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return false }
        cont.resume(returning: value)
        return true
    }

    /// True when this call performed the resume.
    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return false }
        cont.resume(throwing: error)
        return true
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }
}

/// Runs `operation` until it finishes, `timeout` elapses, or the task is cancelled.
nonisolated enum SocketDeadline {
    static func withTimeout<T: Sendable>(_ timeout: Duration,
                                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LocalSocketError.timedOut
            }
            do {
                let value = try await group.next()!
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    static func duration(from request: URLRequest, defaultSeconds: TimeInterval = 45) -> Duration {
        let seconds = request.timeoutInterval > 0 ? request.timeoutInterval : defaultSeconds
        return .seconds(seconds)
    }
}

/// HTTP/1 requests to the local runner over its private Unix socket.
nonisolated enum UnixSocketHTTP {
    static func stream(for request: URLRequest, path: String) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        try await SocketDeadline.withTimeout(SocketDeadline.duration(from: request)) {
            try await streamBody(for: request, path: path)
        }
    }

    static func data(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        try await SocketDeadline.withTimeout(SocketDeadline.duration(from: request)) {
            try await dataBody(for: request, path: path)
        }
    }

#if canImport(Network)
    private static func streamBody(for request: URLRequest, path: String) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        guard let url = request.url else { throw LocalSocketError.noURL }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        try await ready(connection, queue: "com.deskree.oby.runner-events")
        try Task.checkCancellation()
        let target = "\(request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "") HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nAccept: text/event-stream\r\n"
        let headers = (request.allHTTPHeaderFields ?? [:]).map { "\($0.key): \($0.value)\r\n" }.joined()
        var bytes = Data((target + headers + "\r\n").utf8)
        if let body = request.httpBody { bytes.append(body) }
        try await send(connection, bytes)
        var head = Data()
        let marker = Data("\r\n\r\n".utf8)
        while head.range(of: marker) == nil {
            try Task.checkCancellation()
            head.append(try await receive(connection))
        }
        let (response, body) = try parseHead(head, url: url, marker: marker, connection: connection)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            // Keep the pump alive for the stream's lifetime: the receive callback retains it, and
            // onTermination retains it until the consumer cancels or the connection ends.
            let pump = SocketEventPump(connection: connection, continuation: continuation)
            continuation.onTermination = { _ in
                connection.cancel()
                pump.stop()
            }
            pump.read(body)
        }
        return (response, stream)
    }

    private static func dataBody(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw LocalSocketError.noURL }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        try await withTaskCancellationHandler {
            try await ready(connection, queue: "com.deskree.oby.runner-socket")
            try Task.checkCancellation()
            var head = "\(request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "") HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
            for (name, value) in request.allHTTPHeaderFields ?? [:] where name.caseInsensitiveCompare("Host") != .orderedSame {
                head += "\(name): \(value)\r\n"
            }
            let body = request.httpBody ?? Data()
            if request.value(forHTTPHeaderField: "Content-Length") == nil { head += "Content-Length: \(body.count)\r\n" }
            head += "\r\n"
            var outgoing = Data(head.utf8)
            outgoing.append(body)
            try await send(connection, outgoing)
            var incoming = Data()
            let separator = Data("\r\n\r\n".utf8)
            while incoming.range(of: separator) == nil {
                try Task.checkCancellation()
                incoming.append(try await receive(connection))
            }
            guard let range = incoming.range(of: separator),
                  let header = String(data: incoming[..<range.lowerBound], encoding: .utf8),
                  let first = header.components(separatedBy: "\r\n").first,
                  let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
                connection.cancel()
                throw LocalSocketError.badResponse
            }
            var fields: [String: String] = [:]
            for line in header.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else {
                connection.cancel()
                throw LocalSocketError.badHeaders
            }
            var result = Data(incoming[range.upperBound...])
            let length = fields.first(where: { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }).flatMap { Int($0.value) }
            while length.map({ result.count < $0 }) ?? true {
                try Task.checkCancellation()
                let bytes = try await receive(connection, allowEmpty: true)
                guard !bytes.isEmpty else { break }
                result.append(bytes)
            }
            connection.cancel()
            return (result, response)
        } onCancel: {
            connection.cancel()
        }
    }

    /// Waits until the connection is ready. A later `.failed` does not resume again.
    private static func ready(_ connection: NWConnection, queue: String) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: queue))
        }
    }

    private static func send(_ connection: NWConnection, _ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(done)
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { once.resume(throwing: error) } else { once.resume(returning: ()) }
            })
        }
    }

    private static func receive(_ connection: NWConnection, allowEmpty: Bool = false) async throws -> Data {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            let once = ResumeOnce(done)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { once.resume(throwing: error) }
                else if let data, !data.isEmpty { once.resume(returning: data) }
                else if complete {
                    if allowEmpty { once.resume(returning: Data()) }
                    else { once.resume(throwing: LocalSocketError.closedEarly) }
                } else {
                    once.resume(returning: Data())
                }
            }
        }
    }

    private static func parseHead(_ head: Data, url: URL, marker: Data, connection: NWConnection) throws -> (HTTPURLResponse, Data) {
        guard let range = head.range(of: marker),
              let text = String(data: head[..<range.lowerBound], encoding: .utf8),
              let statusLine = text.components(separatedBy: "\r\n").first,
              let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
            connection.cancel()
            throw LocalSocketError.badResponse
        }
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            connection.cancel()
            throw LocalSocketError.badHeaders
        }
        return (response, Data(head[range.upperBound...]))
    }

    nonisolated final class SocketEventPump: @unchecked Sendable {
        let connection: NWConnection
        let continuation: AsyncThrowingStream<UInt8, Error>.Continuation
        private let lock = NSLock()
        private var stopped = false

        init(connection: NWConnection, continuation: AsyncThrowingStream<UInt8, Error>.Continuation) {
            self.connection = connection
            self.continuation = continuation
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            connection.cancel()
        }

        func read(_ initial: Data = Data()) {
            for byte in initial { continuation.yield(byte) }
            // Strong self: the connection holds this callback for the stream's lifetime.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                guard !stopped else { return }
                if let error { self.continuation.finish(throwing: error); self.connection.cancel() }
                else if let data, !data.isEmpty { self.read(data) }
                else if complete { self.continuation.finish(); self.connection.cancel() }
                else { self.read() }
            }
        }
    }
#else
    private static func streamBody(for request: URLRequest, path: String) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        let (data, response) = try await dataBody(for: request, path: path)
        let http = response as! HTTPURLResponse
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
        return (http, stream)
    }

    private static func dataBody(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw LocalSocketError.noURL }
        try Task.checkCancellation()
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw LocalSocketError(message: "Couldn't open a Unix socket.") }
        defer { close(fd) }
        return try await withTaskCancellationHandler {
            try unixConnect(fd: fd, path: path)
            try Task.checkCancellation()
            var head = "\(request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "") HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
            for (name, value) in request.allHTTPHeaderFields ?? [:] where name.caseInsensitiveCompare("Host") != .orderedSame {
                head += "\(name): \(value)\r\n"
            }
            let body = request.httpBody ?? Data()
            if request.value(forHTTPHeaderField: "Content-Length") == nil { head += "Content-Length: \(body.count)\r\n" }
            head += "\r\n"
            var outgoing = Data(head.utf8)
            outgoing.append(body)
            try writeAll(fd: fd, outgoing)
            var incoming = Data()
            let separator = Data("\r\n\r\n".utf8)
            while incoming.range(of: separator) == nil {
                try Task.checkCancellation()
                let chunk = try readSome(fd: fd)
                guard !chunk.isEmpty else { throw LocalSocketError.closedEarly }
                incoming.append(chunk)
            }
            guard let range = incoming.range(of: separator),
                  let header = String(data: incoming[..<range.lowerBound], encoding: .utf8),
                  let first = header.components(separatedBy: "\r\n").first,
                  let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
                throw LocalSocketError.badResponse
            }
            var fields: [String: String] = [:]
            for line in header.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else {
                throw LocalSocketError.badHeaders
            }
            var result = Data(incoming[range.upperBound...])
            let length = fields.first(where: { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }).flatMap { Int($0.value) }
            while length.map({ result.count < $0 }) ?? true {
                try Task.checkCancellation()
                let bytes = try readSome(fd: fd)
                guard !bytes.isEmpty else { break }
                result.append(bytes)
            }
            return (result, response)
        } onCancel: {
            // Unblock a stuck read/write without racing defer's close.
            _ = shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    private static func unixConnect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path) - 1
        let utf8 = Array(path.utf8)
        guard utf8.count <= maxPath else { throw LocalSocketError(message: "The Unix socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in utf8.enumerated() { buffer[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, size) }
        }
        guard result == 0 else { throw LocalSocketError(message: "Couldn't connect to the local runner socket.") }
    }

    private static func writeAll(fd: Int32, _ data: Data) throws {
        var sent = 0
        let total = data.count
        while sent < total {
            try Task.checkCancellation()
            let n = data.withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress!.advanced(by: sent), total - sent)
            }
            if n < 0 { throw LocalSocketError(message: "Couldn't write to the local runner socket.") }
            sent += n
        }
    }

    private static func readSome(fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        if n < 0 { throw LocalSocketError(message: "Couldn't read from the local runner socket.") }
        if n == 0 { return Data() }
        return Data(buffer[..<n])
    }
#endif
}
