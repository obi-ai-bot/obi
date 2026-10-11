import Foundation
import Hummingbird
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import ObyEngine

/// Runner-owned CPU transcription. Audio is never passed through Shell, agents or the journal.
actor Speech {
    struct Config: Sendable {
        var cli: URL
        var fastModel: URL
        var finalModel: URL
        var folder: URL
        var threads: Int = 8
        /// Optional owner override; otherwise use product names and the desk's current repositories.
        var names: [String]?
        var timeout: Double = 120
        var idleTimeout: Double = 120

        static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            let root = Workspace.root.appending(path: "whisper")
            return Self(cli: URL(filePath: env["OBY_WHISPER_CLI"] ?? root.appending(path: "bin/whisper-cli").path),
                        fastModel: URL(filePath: env["OBY_WHISPER_FAST_MODEL"] ?? root.appending(path: "models/ggml-base-q5_1.bin").path),
                        finalModel: URL(filePath: env["OBY_WHISPER_FINAL_MODEL"] ?? root.appending(path: "models/ggml-large-v3-turbo.bin").path),
                        folder: root.appending(path: "audio"),
                        threads: Int(env["OBY_WHISPER_THREADS"] ?? "8") ?? 0,
                        names: env["OBY_SPEECH_NAMES"].map { $0.split(separator: ",").map(String.init) })
        }

        func prompt(repos: [String]) -> String {
            let words = names ?? (["oby", "tetrix"] + repos.compactMap { $0.split(separator: "/").last.map(String.init) })
            var prompt = "", seen: Set<String> = []
            for word in words {
                let name = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                let next = (prompt.isEmpty ? "" : ", ") + name
                for character in next {
                    guard prompt.utf8.count + String(character).utf8.count <= 512 else { return prompt }
                    prompt.append(character)
                }
            }
            return prompt
        }
    }

    struct Answer: Encodable, Sendable {
        var utterance: String
        var text: String
        var final: Bool
    }
    private struct Session {
        var id: String
        var language: String
        var pcm: Data
        var expiry: UUID
    }
    static let maxBytes = 60 * 16_000 * 2
    // Each request is a short chunk (up to ten seconds, plus WAV metadata).
    static let chunkBytes = 320_000 + 4096
    let config: Config
    private var sessions: [String: Session] = [:]
    private var busy: Set<String> = []

    init(config: Config = .environment()) { self.config = config }

    /// Call once at runner startup, before serving requests, to remove crash leftovers.
    func discardAbandonedAudio() throws {
        if FileManager.default.fileExists(atPath: config.folder.path) {
            try FileManager.default.removeItem(at: config.folder)
        }
    }

    nonisolated func handle(_ request: Request, repos: [String]) async throws -> Answer {
        let query = request.uri.queryParameters
        guard let device = query.get("device"), UUID(uuidString: device) != nil,
              let utterance = query.get("utterance"), UUID(uuidString: utterance) != nil else {
            throw APIError(.badRequest, "device and utterance must be UUIDs.")
        }
        let flag = query.get("final") ?? "false"
        guard ["true", "false"].contains(flag) else { throw APIError(.badRequest, "final is true or false.") }
        let language = query.get("language") ?? "auto"
        guard ["auto", "en", "pt"].contains(language) else { throw APIError(.badRequest, "language is auto, en or pt.") }
        let type = request.headers[.contentType]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard ["application/octet-stream", "audio/pcm", "audio/wav", "audio/x-wav"].contains(type) else {
            throw APIError(.unsupportedMediaType, "Send 16 kHz mono signed 16-bit little-endian PCM or WAV.")
        }
        var request = request
        let bytes: ByteBuffer
        do { bytes = try await request.collectBody(upTo: Self.chunkBytes) }
        catch let error as any HTTPResponseError where error.status == .contentTooLarge {
            throw APIError(.contentTooLarge, "Send chunks of at most ten seconds with at most 4096 bytes of WAV metadata.")
        }
        return try await transcribe(device: device.lowercased(), utterance: utterance.lowercased(),
                                    audio: Data(bytes.readableBytesView), wav: type.contains("wav"),
                                    final: flag == "true", language: language, repos: repos)
    }

    func transcribe(device: String, utterance: String, audio: Data, wav: Bool = false,
                    final: Bool = false, language: String = "auto", repos: [String] = []) async throws -> Answer {
        guard !busy.contains(device) else { throw APIError(.conflict, "This device already has a transcription running.") }
        guard busy.count < 2 else { throw APIError(.serviceUnavailable, "The speech service is busy. Try again later.") }
        guard config.threads > 0 else { throw APIError(.notImplemented, "OBY_WHISPER_THREADS must be positive.") }
        guard Self.regularNonempty(config.cli), FileManager.default.isExecutableFile(atPath: config.cli.path) else {
            throw APIError(.notImplemented, "whisper-cli is missing or not an executable file. Run Runner/scripts/setup-whisper.sh on the runner.")
        }
        for model in [config.fastModel, config.finalModel] {
            guard Self.regularNonempty(model), FileManager.default.isReadableFile(atPath: model.path) else {
                throw APIError(.notImplemented, "A Whisper model is missing or empty: \(model.lastPathComponent). Run Runner/scripts/setup-whisper.sh.")
            }
        }
        if let session = sessions[device], session.id != utterance || session.language != language {
            throw APIError(.conflict, "Finish this device's current utterance first, or wait for its idle expiry.")
        }
        guard sessions[device] != nil || sessions.count < 32 else { throw APIError(.serviceUnavailable, "Too many open utterances. Try again later.") }
        let pcm = wav && !audio.isEmpty ? try Self.pcm(audio) : audio
        guard pcm.count <= 320_000 else { throw APIError(.contentTooLarge, "Send chunks of at most ten seconds.") }
        guard pcm.count % 2 == 0 else { throw APIError(.badRequest, "PCM must contain complete 16-bit samples.") }
        var session = sessions[device] ?? Session(id: utterance, language: language, pcm: Data(), expiry: UUID())
        guard session.pcm.count + pcm.count <= Self.maxBytes else {
            sessions[device] = nil
            throw APIError(.contentTooLarge, "An utterance may contain at most 60 seconds of audio.")
        }
        session.pcm.append(pcm)
        guard !session.pcm.isEmpty else { throw APIError(.badRequest, "Send audio before finishing an utterance.") }
        session.expiry = UUID()
        sessions[device] = session
        busy.insert(device)
        defer { busy.remove(device) }
        do {
            let config = config, fullAudio = session.pcm, prompt = config.prompt(repos: repos)
            let text = try await Task.detached {
                try Self.run(config: config, pcm: fullAudio, final: final, language: language, prompt: prompt)
            }.value
            if final { sessions[device] = nil }
            else {
                let token = session.expiry, idleTimeout = config.idleTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(idleTimeout))
                    await self?.expire(device: device, token: token)
                }
            }
            return Answer(utterance: utterance, text: text, final: final)
        } catch {
            sessions[device] = nil
            // No subprocess output, transcript, audio, or file paths in errors/logs.
            throw APIError(.internalServerError, "Whisper couldn't transcribe the audio. The utterance was discarded.")
        }
    }

    private func expire(device: String, token: UUID) {
        if sessions[device]?.expiry == token && !busy.contains(device) { sessions[device] = nil }
    }

    /// Strict RIFF parser: validate every chunk before passing normalized PCM to whisper.cpp.
    static func pcm(_ wav: Data) throws -> Data {
        let b = [UInt8](wav)
        func word(_ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) } }
        func tag(_ i: Int) -> String { String(bytes: b[i..<i+4], encoding: .ascii) ?? "" }
        func invalid() -> APIError { APIError(.badRequest, "WAV must be 16 kHz mono 16-bit PCM with valid RIFF chunks.") }
        guard b.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE", word(4, 4) == b.count - 8 else { throw invalid() }
        var offset = 12, format = false, samples: Data?
        while offset + 8 <= b.count {
            let size = word(offset + 4, 4), start = offset + 8
            guard size <= b.count - start else { throw invalid() }
            switch tag(offset) {
            case "fmt ":
                guard !format, size >= 16, word(start, 2) == 1, word(start + 2, 2) == 1,
                      word(start + 4, 4) == 16_000, word(start + 8, 4) == 32_000,
                      word(start + 12, 2) == 2, word(start + 14, 2) == 16 else { throw invalid() }
                format = true
            case "data":
                guard samples == nil, size % 2 == 0 else { throw invalid() }
                samples = Data(b[start..<start + size])
            default: break
            }
            offset = start + size + size % 2
        }
        guard offset == b.count, format, let samples else { throw invalid() }
        return samples
    }

    static func wave(_ pcm: Data) -> Data {
        var result = Data()
        func tag(_ value: String) { result.append(contentsOf: value.utf8) }
        func number(_ value: Int, _ count: Int) { for i in 0..<count { result.append(UInt8((value >> (8 * i)) & 255)) } }
        tag("RIFF"); number(pcm.count + 36, 4); tag("WAVEfmt "); number(16, 4)
        number(1, 2); number(1, 2); number(16_000, 4); number(32_000, 4); number(2, 2); number(16, 2)
        tag("data"); number(pcm.count, 4); result.append(pcm)
        return result
    }

    private static func regularNonempty(_ url: URL) -> Bool {
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private static func run(config: Config, pcm: Data, final: Bool, language: String, prompt: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: config.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = config.folder.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let audio = folder.appending(path: "audio.wav"), output = folder.appending(path: "text")
        try wave(pcm).write(to: audio)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
        let process = Process()
        process.executableURL = config.cli
        process.currentDirectoryURL = folder
        process.arguments = ["--model", (final ? config.finalModel : config.fastModel).path,
                             "--threads", String(config.threads), "--language", language,
                             "--prompt", prompt, "--no-gpu", "--no-prints",
                             "--output-txt", "--output-file", output.path, "--file", audio.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A hung CLI cannot retain audio forever. SIGKILL also handles a CLI ignoring SIGTERM.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + config.timeout)
        timer.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw APIError(.internalServerError, "Whisper failed.") }
        let text = try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try fm.removeItem(at: folder)
        return text
    }
}
