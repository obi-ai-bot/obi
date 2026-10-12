import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A single loopback HTTP connection, authenticated before sending any request bytes.
/// Checking only a listening port before URLSession connects leaves a takeover race.
/// Instead match this connection's peer socket to the spawned child's descriptors.
/// Once verified, the same socket carries the request; it cannot redirect or reconnect.
enum WhisperConnection {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    static func request(pid: Int32, port: Int, path: String, timeout: Double,
                        body: Data? = nil, contentType: String? = nil) async throws -> Response {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw URLError(.cannotConnectToHost) }
        #if !os(Linux)
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
        #endif
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        func pause() async throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        #if !os(Linux)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 || errno == EINPROGRESS else { throw URLError(.cannotConnectToHost) }
        while true {
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&event, 1, 0)
            guard polled >= 0 || errno == EINTR else { throw URLError(.cannotConnectToHost) }
            if polled > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw URLError(.cannotConnectToHost)
                }
                break
            }
            try await pause()
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw URLError(.cannotConnectToHost) }
        let localPort = Int(UInt16(bigEndian: local.sin_port))
        // accept() may lag behind connect(). Wait briefly for the child to own the
        // accepted socket, without sending even the headers to an unverified peer.
        let ownershipDeadline = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(500)))
        while !ownsPeer(pid: pid, port: port, clientPort: localPort) {
            guard ContinuousClock.now < ownershipDeadline else { throw URLError(.cannotConnectToHost) }
            try await pause()
        }
        var request = Data("\(body == nil ? "GET" : "POST") \(path) HTTP/1.0\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n".utf8)
        if let body, let contentType {
            request.append(contentsOf: "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n".utf8)
        }
        request.append(contentsOf: "\r\n".utf8)
        if let body { request.append(body) }
        var offset = 0
        while offset < request.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            let sent = request.withUnsafeBytes { bytes in
                #if os(Linux)
                send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #endif
            }
            if sent > 0 { offset += sent }
            else if sent < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { try await pause() }
            else { throw URLError(.networkConnectionLost) }
        }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                // A 60-second transcript fits comfortably; bound an invalid response.
                guard received.count <= 4 * 1024 * 1024 else { throw URLError(.badServerResponse) }
            } else if count == 0 { break }
            else if [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { try await pause() }
            else { throw URLError(.networkConnectionLost) }
        }
        guard let separator = received.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: received[..<separator.lowerBound], encoding: .utf8),
              let first = headers.components(separatedBy: "\r\n").first,
              first.hasPrefix("HTTP/1."), let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw URLError(.badServerResponse)
        }
        let responseBody = Data(received[separator.upperBound...])
        // HTTP/1.0 + Connection: close requests an unchunked, EOF-delimited response.
        // Fail closed on unsupported framing or a truncated Content-Length.
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw URLError(.badServerResponse) }
            let name = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { throw URLError(.badServerResponse) }
            if name == "content-length", Int(value) != responseBody.count { throw URLError(.badServerResponse) }
        }
        return Response(status: status, body: responseBody)
    }

    private static func ownsPeer(pid: Int32, port: Int, clientPort: Int) -> Bool {
        #if os(Linux)
        // Look up the *accepted* server endpoint, not merely its listening socket.
        // An attacker that rebinds the port after connect() cannot acquire this socket.
        // Foundation's String(contentsOfFile:) can stop after the first procfs
        // page. Read through EOF so busy hosts' later sockets are included.
        guard let table = try? FileHandle(forReadingFrom: URL(filePath: "/proc/net/tcp")) else { return false }
        defer { try? table.close() }
        guard let data = try? table.readToEnd(),
              let descriptors = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd") else { return false }
        let tcp = String(decoding: data, as: UTF8.self)
        let local = String(format: "0100007F:%04X", port)
        let remote = String(format: "0100007F:%04X", clientPort)
        let inodes = Set(tcp.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 9, fields[1] == local, fields[2] == remote, fields[3] == "01" else { return nil }
            return "socket:[\(fields[9])]"
        })
        guard !inodes.isEmpty else { return false }
        return descriptors.contains {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\($0)") else { return false }
            return inodes.contains(target)
        }
        #else
        // Darwin exposes socket ownership through lsof rather than procfs. Invoke
        // it directly, with no shell or inherited credentials, and fail closed.
        let query = Process(), output = Pipe()
        query.executableURL = URL(filePath: "/usr/sbin/lsof")
        query.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:ESTABLISHED", "-Fn"]
        query.environment = ["PATH": "/usr/bin:/bin"]
        query.standardOutput = output
        query.standardError = FileHandle.nullDevice
        guard (try? query.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        query.waitUntilExit()
        return query.terminationStatus == 0 && String(decoding: data, as: UTF8.self)
            .split(separator: "\n").contains("n127.0.0.1:\(port)->127.0.0.1:\(clientPort)")
        #endif
    }
}
