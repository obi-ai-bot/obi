import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The stable public prefix of zlib's `z_stream`, loaded dynamically so Engine stays buildable in
/// both SwiftPM and the Xcode project without adding a platform-specific compression dependency.
private nonisolated struct PDFZStream {
    var nextIn: UnsafeMutablePointer<UInt8>?
    var availIn: UInt32 = 0
    var totalIn: UInt = 0
    var nextOut: UnsafeMutablePointer<UInt8>?
    var availOut: UInt32 = 0
    var totalOut: UInt = 0
    var message: UnsafePointer<CChar>?
    var state: UnsafeMutableRawPointer?
    var allocate: UnsafeMutableRawPointer?
    var release: UnsafeMutableRawPointer?
    var opaque: UnsafeMutableRawPointer?
    var dataType: Int32 = 0
    var adler: UInt = 0
    var reserved: UInt = 0
}

private nonisolated enum PDFFlate {
    nonisolated static func inflate(_ input: [UInt8], maximumOutput: Int) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        #if os(Linux)
        let candidates = ["libz.so.1", "libz.so"]
        #else
        let candidates = ["libz.dylib", "/usr/lib/libz.1.dylib"]
        #endif
        let library = candidates.lazy.compactMap { name -> UnsafeMutableRawPointer? in
            name.withCString { dlopen($0, RTLD_NOW) }
        }.first
        guard let library else { return nil }
        defer { dlclose(library) }

        typealias Version = @convention(c) () -> UnsafePointer<CChar>?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32) -> Int32
        typealias Inflate = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        typealias Finish = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        guard let versionSymbol = dlsym(library, "zlibVersion"),
              let initializeSymbol = dlsym(library, "inflateInit2_"),
              let inflateSymbol = dlsym(library, "inflate"),
              let finishSymbol = dlsym(library, "inflateEnd") else { return nil }
        let version = unsafeBitCast(versionSymbol, to: Version.self)
        let initialize = unsafeBitCast(initializeSymbol, to: Initialize.self)
        let inflate = unsafeBitCast(inflateSymbol, to: Inflate.self)
        let finish = unsafeBitCast(finishSymbol, to: Finish.self)

        var stream = PDFZStream()
        return withUnsafeMutablePointer(to: &stream) { pointer in
            let rawStream = UnsafeMutableRawPointer(pointer)
            guard initialize(rawStream, 15, version(), Int32(MemoryLayout<PDFZStream>.size)) == 0 else { return nil }
            defer { _ = finish(rawStream) }
            return input.withUnsafeBufferPointer { source in
                pointer.pointee.nextIn = UnsafeMutablePointer(mutating: source.baseAddress)
                pointer.pointee.availIn = UInt32(source.count)
                var decoded: [UInt8] = []
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let previousInput = pointer.pointee.availIn
                    var status: Int32 = 0
                    var produced = 0
                    chunk.withUnsafeMutableBufferPointer { destination in
                        pointer.pointee.nextOut = destination.baseAddress
                        pointer.pointee.availOut = UInt32(destination.count)
                        status = inflate(rawStream, 0) // Z_NO_FLUSH
                        produced = destination.count - Int(pointer.pointee.availOut)
                        if decoded.count + produced <= maximumOutput {
                            decoded.append(contentsOf: destination.prefix(produced))
                        } else {
                            status = -3 // Z_MEM_ERROR: refuse an excessive expansion.
                        }
                    }
                    if status == 1 { return decoded } // Z_STREAM_END
                    guard status == 0, produced > 0 || pointer.pointee.availIn < previousInput else { return nil }
                }
            }
        }
    }
}

/// A file owned by this runner. Its opaque id is the only identifier clients can use.
nonisolated struct Attachment: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var created: Date
    var name: String
    var type: String
    var bytes: Int
    var sha256: String
    var width: Int?
    var height: Int?
    var pages: Int?
    var source: String
    var turn: String?
    var jobs: [String]
    var secretHit: Bool

    var reference: AttachmentRef {
        AttachmentRef(id: id, name: name, type: type, bytes: bytes, width: width, height: height, pages: pages)
    }
}

nonisolated struct AttachmentRef: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var type: String
    var bytes: Int
    var width: Int?
    var height: Int?
    var pages: Int?
}

nonisolated enum AttachmentStoreError: Error, LocalizedError {
    case tooLarge
    case messageTooLarge
    case empty
    case secret(String)
    case unknown
    case linked
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "An attachment may be at most 25 MB."
        case .messageTooLarge: "Attachments in one message may total 50 MB."
        case .empty: "An attachment can't be empty."
        case .secret(let name): "This file holds the vault secret \(name), so it wasn't uploaded."
        case .unknown: "There's no attachment with that id."
        case .linked: "This attachment is already linked to a turn or job."
        case .invalid(let why): why
        }
    }
}

/// Runner-owned attachment bytes and their durable metadata.
nonisolated final class AttachmentStore {
    static let maxBytes = 25 * 1024 * 1024
    static let maxMessageBytes = 50 * 1024 * 1024
    let root: URL
    let jobs: JobStore
    let vault: Vault

    init(root: URL = Workspace.root.appending(path: "attachments", directoryHint: .isDirectory), jobs: JobStore, vault: Vault = .shared) {
        self.root = root
        self.jobs = jobs
        self.vault = vault
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = chmod(root.path, mode_t(0o700))
    }

    func upload(_ data: Data, name: String, source: String) throws -> Attachment {
        guard !data.isEmpty else { throw AttachmentStoreError.empty }
        guard data.count <= Self.maxBytes else { throw AttachmentStoreError.tooLarge }
        guard ["mac", "iphone"].contains(source) else { throw AttachmentStoreError.invalid("source is mac or iphone.") }
        let sniffed = Self.sniff(data)
        let leaks = try vault.forAgents()
        let decoded = sniffed.type == "text/plain" ? String(data: data, encoding: .utf8) : nil
        let secretHit = decoded.map { !leaks.hits(in: $0).isEmpty } ?? false
        let kept: Data
        if let decoded {
            kept = Data(leaks.redact(decoded).utf8)
        } else {
            if let hit = leaks.hits(in: String(decoding: data, as: UTF8.self)).first { throw AttachmentStoreError.secret(hit.name) }
            kept = data
        }
        let id = Self.opaqueID()
        let path = root.appending(path: id)
        guard Self.validID(id) else { throw AttachmentStoreError.invalid("Couldn't make an attachment id.") }
        try kept.write(to: path, options: .atomic)
        _ = chmod(path.path, mode_t(0o600))
        let dimensions = Self.pngDimensions(kept)
        let metadata = Attachment(id: id, created: .now, name: Self.displayName(name), type: sniffed.type,
                                  bytes: kept.count, sha256: Self.sha256(kept), width: dimensions?.0, height: dimensions?.1,
                                  pages: sniffed.type == "application/pdf" ? Self.pdfPages(kept) : nil,
                                  source: source, turn: nil, jobs: [], secretHit: secretHit)
        jobs.save(metadata)
        return metadata
    }

    func attachment(_ id: String) -> Attachment? {
        guard Self.validID(id) else { return nil }
        return jobs.attachment(id)
    }

    func content(_ id: String) throws -> (Attachment, Data) {
        guard let metadata = attachment(id) else { throw AttachmentStoreError.unknown }
        let path = root.appending(path: id)
        guard let data = try? Data(contentsOf: path) else { throw AttachmentStoreError.unknown }
        return (metadata, data)
    }

    func delete(_ id: String) throws {
        guard let attachment = attachment(id) else { throw AttachmentStoreError.unknown }
        guard attachment.turn == nil && attachment.jobs.isEmpty else { throw AttachmentStoreError.linked }
        try? FileManager.default.removeItem(at: root.appending(path: id))
        jobs.deleteAttachment(id)
    }

    func validate(_ ids: [String], limit: Int = 10) throws -> [Attachment] {
        guard ids.count <= limit, Set(ids).count == ids.count else { throw AttachmentStoreError.invalid("attachmentIds holds at most \(limit) distinct ids.") }
        var result: [Attachment] = []
        var totalBytes = 0
        for id in ids {
            guard let value = attachment(id), FileManager.default.fileExists(atPath: root.appending(path: id).path) else {
                throw AttachmentStoreError.invalid("Unknown attachment id \(id).")
            }
            guard value.turn == nil else { throw AttachmentStoreError.invalid("Attachment \(id) is already linked to a turn.") }
            guard value.bytes >= 0, totalBytes <= Self.maxMessageBytes - value.bytes else {
                throw AttachmentStoreError.messageTooLarge
            }
            totalBytes += value.bytes
            result.append(value)
        }
        return result
    }

    func link(_ ids: [String], toJob job: String) throws {
        for id in ids {
            guard var value = attachment(id) else { throw AttachmentStoreError.unknown }
            if !value.jobs.contains(job) { value.jobs.append(job); jobs.save(value) }
        }
    }

    func link(_ ids: [String], toTurn turn: String) throws {
        for id in ids {
            guard var value = attachment(id) else { throw AttachmentStoreError.unknown }
            value.turn = turn
            jobs.save(value)
        }
    }

    func url(_ id: String) -> URL? {
        guard attachment(id) != nil else { return nil }
        return root.appending(path: id)
    }

    func thumbnail(_ id: String) throws -> Data? {
        guard let metadata = attachment(id), metadata.type.hasPrefix("image/"), let source = url(id) else { throw AttachmentStoreError.unknown }
        #if canImport(ImageIO)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
        #else
        let output = FileManager.default.temporaryDirectory.appending(path: "oby-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let tools = ["/usr/bin/vipsthumbnail", "/usr/local/bin/vipsthumbnail", "/usr/bin/convert", "/usr/local/bin/convert"]
        guard let executable = tools.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = executable.hasSuffix("vipsthumbnail")
            ? [source.path, "--size", "320x320", "--output", output.path]
            : [source.path, "-thumbnail", "320x320", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: output)
        #endif
    }

    func cleanup(now: Date = .now, liveTurns: Set<String>, liveJobs: Set<String>) {
        for var value in jobs.attachments() {
            if value.turn == nil && value.jobs.isEmpty && value.created < now.addingTimeInterval(-24 * 60 * 60) {
                try? FileManager.default.removeItem(at: root.appending(path: value.id))
                jobs.deleteAttachment(value.id)
                continue
            }
            if let turn = value.turn, !liveTurns.contains(turn) { value.turn = nil }
            value.jobs.removeAll { !liveJobs.contains($0) }
            if value.turn == nil && value.jobs.isEmpty && value.created < now.addingTimeInterval(-24 * 60 * 60) {
                try? FileManager.default.removeItem(at: root.appending(path: value.id))
                jobs.deleteAttachment(value.id)
            } else {
                jobs.save(value)
            }
        }
    }

    static func validID(_ id: String) -> Bool { id.count == 16 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    private static func opaqueID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%x", UInt8.random(in: 0...15, using: &generator)) }.joined()
    }

    private static func displayName(_ raw: String) -> String {
        let name = URL(filePath: raw).lastPathComponent
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()")).contains($0) }.prefix(120))
        return safe.isEmpty || safe == "." || safe == ".." ? "attachment" : safe
    }

    private static func sniff(_ data: Data) -> (type: String, ext: String) {
        let b = [UInt8](data.prefix(16))
        if b.starts(with: [137,80,78,71,13,10,26,10]) { return ("image/png", "png") }
        if b.starts(with: [255,216,255]) { return ("image/jpeg", "jpg") }
        if b.starts(with: Array("GIF8".utf8)) { return ("image/gif", "gif") }
        if data.count >= 12, String(decoding: data[8..<12], as: UTF8.self) == "WEBP" { return ("image/webp", "webp") }
        if b.starts(with: Array("%PDF-".utf8)) { return ("application/pdf", "pdf") }
        if data.count >= 12, String(decoding: data[4..<8], as: UTF8.self) == "ftyp",
           ["heic", "heix", "hevc", "mif1"].contains(String(decoding: data[8..<12], as: UTF8.self)) { return ("image/heic", "heic") }
        if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || ["\n", "\r", "\t"].contains(String($0)) }) { return ("text/plain", "txt") }
        return ("application/octet-stream", "bin")
    }

    private static func pngDimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24, data.starts(with: [137,80,78,71,13,10,26,10]) else { return nil }
        func integer(_ range: Range<Int>) -> Int { range.reduce(0) { ($0 << 8) | Int(data[$1]) } }
        return (integer(16..<20), integer(20..<24))
    }

    private static func pdfPages(_ data: Data) -> Int? {
        guard var text = String(data: data, encoding: .isoLatin1) else { return nil }
        var decodedBytes = 0
        for stream in pdfObjectStreams([UInt8](data)) {
            guard let decoded = PDFFlate.inflate(stream, maximumOutput: 50 * 1024 * 1024),
                  decodedBytes <= 50 * 1024 * 1024 - decoded.count,
                  let decodedText = String(data: Data(decoded), encoding: .isoLatin1) else { continue }
            decodedBytes += decoded.count
            text += decodedText
        }
        let count = text.matches(of: /\/Type\s*\/Page(?!s)/).count
        return count > 0 ? count : nil
    }

    /// PDF 1.5 object streams hold page dictionaries compressed with FlateDecode. Expand those
    /// streams before counting `/Type /Page`; otherwise a valid compressed PDF looks like it has
    /// no pages and the brain incorrectly treats it as over the 100-page limit.
    private static func pdfObjectStreams(_ bytes: [UInt8]) -> [[UInt8]] {
        let streamToken = Array("stream".utf8)
        let endToken = Array("endstream".utf8)
        var output: [[UInt8]] = []
        var cursor = 0
        while let marker = find(streamToken, in: bytes, from: cursor) {
            cursor = marker.upperBound
            guard marker.lowerBound > 0, isWhitespace(bytes[marker.lowerBound - 1]),
                  marker.upperBound < bytes.count else { continue }
            var start = marker.upperBound
            if bytes[start] == 13 {
                start += 1
                if start < bytes.count, bytes[start] == 10 { start += 1 }
            } else if bytes[start] == 10 {
                start += 1
            } else { continue }

            guard let dictionaryEnd = lastRange(Array(">>".utf8), in: bytes, before: marker.lowerBound),
                  bytes[dictionaryEnd.upperBound..<marker.lowerBound].allSatisfy(isWhitespace),
                  let dictionaryStart = lastRange(Array("<<".utf8), in: bytes, before: dictionaryEnd.lowerBound) else { continue }
            let dictionary = String(decoding: bytes[dictionaryStart.lowerBound..<dictionaryEnd.upperBound], as: UTF8.self)
            guard dictionary.contains(/\/Type\s*\/ObjStm\b/),
                  dictionary.contains(/\/Filter\s*(?:\[\s*)?\/(?:FlateDecode|Fl)\b/) else { continue }

            var end: Int?
            if let match = dictionary.firstMatch(of: /\/Length\s+(\d+)\b/),
               let length = Int(match.1), start <= bytes.count - length {
                let exactEnd = start + length
                var trailing = exactEnd
                while trailing < bytes.count, isWhitespace(bytes[trailing]) { trailing += 1 }
                if starts(with: endToken, in: bytes, at: trailing) { end = exactEnd }
            }
            if end == nil, let endMarker = find(endToken, in: bytes, from: start) {
                var candidate = endMarker.lowerBound
                while candidate > start, bytes[candidate - 1] == 10 || bytes[candidate - 1] == 13 { candidate -= 1 }
                end = candidate
            }
            if let end, end >= start { output.append(Array(bytes[start..<end])) }
        }
        return output
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Range<Int>? {
        guard !needle.isEmpty, start >= 0, start <= bytes.count - needle.count else { return nil }
        for index in start...(bytes.count - needle.count) where bytes[index..<(index + needle.count)].elementsEqual(needle) {
            return index..<(index + needle.count)
        }
        return nil
    }

    private static func lastRange(_ needle: [UInt8], in bytes: [UInt8], before end: Int) -> Range<Int>? {
        guard !needle.isEmpty, end >= needle.count else { return nil }
        for index in stride(from: end - needle.count, through: 0, by: -1)
        where bytes[index..<(index + needle.count)].elementsEqual(needle) {
            return index..<(index + needle.count)
        }
        return nil
    }

    private static func starts(with needle: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        index >= 0 && index <= bytes.count - needle.count && bytes[index..<(index + needle.count)].elementsEqual(needle)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }

    private static func sha256(_ data: Data) -> String {
        let constants: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
        ]
        var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var bytes = [UInt8](data)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff)) }
        @inline(__always) func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 { (value >> amount) | (value << (32 - amount)) }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let start = offset + i * 4
                words[i] = (UInt32(bytes[start]) << 24) | (UInt32(bytes[start + 1]) << 16) | (UInt32(bytes[start + 2]) << 8) | UInt32(bytes[start + 3])
            }
            for i in 16..<64 {
                let a = rotate(words[i - 15], 7) ^ rotate(words[i - 15], 18) ^ (words[i - 15] >> 3)
                let b = rotate(words[i - 2], 17) ^ rotate(words[i - 2], 19) ^ (words[i - 2] >> 10)
                words[i] = words[i - 16] &+ a &+ words[i - 7] &+ b
            }
            var (a,b,c,d,e,f,g,h) = (state[0],state[1],state[2],state[3],state[4],state[5],state[6],state[7])
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choose &+ constants[i] &+ words[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                (a,b,c,d,e,f,g,h) = (t1 &+ t2,a,b,c,d &+ t1,e,f,g)
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }
}
