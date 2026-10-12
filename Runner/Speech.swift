import Foundation
import Hummingbird
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import ObyEngine

/// Runner-owned CPU transcription. Audio is never passed through Shell, agents or the journal.
actor Speech {
    struct Config: Sendable {
        var server: URL
        var fastModel: URL
        var finalModel: URL
        var folder: URL
        var threads: Int = 8
        var fastPort: Int = 8171
        var finalPort: Int = 8172
        var startupTimeout: Double = 120
        var warmup: Bool = true
        /// Optional owner override; otherwise use product names and the desk's current repositories.
        var names: [String]?
        var timeout: Double = 120
        var idleTimeout: Double = 120

        static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            let root = Workspace.root.appending(path: "whisper")
            return Self(server: URL(filePath: env["OBY_WHISPER_SERVER"] ?? root.appending(path: "bin/whisper-server").path),
                        fastModel: URL(filePath: env["OBY_WHISPER_FAST_MODEL"] ?? root.appending(path: "models/ggml-base-q5_1.bin").path),
                        finalModel: URL(filePath: env["OBY_WHISPER_FINAL_MODEL"] ?? root.appending(path: "models/ggml-small-q5_1.bin").path),
                        folder: root.appending(path: "audio"),
                        threads: Int(env["OBY_WHISPER_THREADS"] ?? "8") ?? 0,
                        fastPort: Int(env["OBY_WHISPER_FAST_PORT"] ?? "8171") ?? 0,
                        finalPort: Int(env["OBY_WHISPER_FINAL_PORT"] ?? "8172") ?? 0,
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

    struct Transcript: Sendable {
        var text: String
        var language: String?
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
        var expiresAt = Date.distantFuture
        var detectedLanguage: String? = nil
    }
    static let maxBytes = 60 * 16_000 * 2
    // Each request is a short chunk (up to ten seconds, plus WAV metadata).
    static let chunkBytes = 320_000 + 4096
    let config: Config
    private var sessions: [String: Session] = [:]
    private var busy: Set<String> = []
    private var servers: [URL: WhisperServer] = [:]
    private var stopping = false

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
        guard !stopping else { throw APIError(.serviceUnavailable, "The speech service is stopping.") }
        guard !busy.contains(device) else { throw APIError(.conflict, "This device already has a transcription running.") }
        guard busy.count < 2 else { throw APIError(.serviceUnavailable, "The speech service is busy. Try again later.") }
        guard config.threads > 0 else { throw APIError(.notImplemented, "OBY_WHISPER_THREADS must be positive.") }
        guard Self.regularNonempty(config.server), FileManager.default.isExecutableFile(atPath: config.server.path) else {
            throw APIError(.notImplemented, "whisper-server is missing or not an executable file. Run Runner/scripts/setup-whisper.sh on the runner.")
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
        let previous = sessions[device]
        var session = previous ?? Session(id: utterance, language: language, pcm: Data(), expiry: UUID())
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
            let model = final ? config.finalModel : config.fastModel
            let inferenceLanguage = final && language == "auto" ? (session.detectedLanguage ?? language) : language
            let result = try await server(for: model).transcribe(pcm: session.pcm, language: inferenceLanguage, prompt: config.prompt(repos: repos))
            if !final, language == "auto", session.pcm.count >= 5 * 32_000 {
                session.detectedLanguage = result.language
                sessions[device] = session
            }
            if final { sessions[device] = nil }
            else {
                session.expiresAt = Date().addingTimeInterval(config.idleTimeout)
                sessions[device] = session
                scheduleExpiry(device: device, session: session)
            }
            return Answer(utterance: utterance, text: result.text, final: final)
        } catch {
            if let error = error as? APIError, error.status == .serviceUnavailable {
                // A rejected chunk is not consumed. Preserve the preceding audio and
                // its original idle deadline so the client can retry exactly once.
                sessions[device] = previous
                if let previous { scheduleExpiry(device: device, session: previous) }
                throw error
            }
            sessions[device] = nil
            // No subprocess output, transcript, audio, or file paths in errors/logs.
            throw APIError(.internalServerError, "Whisper couldn't transcribe the audio. The utterance was discarded.")
        }
    }

    private func scheduleExpiry(device: String, session: Session) {
        let token = session.expiry, delay = max(0, session.expiresAt.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.expire(device: device, token: token)
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

    static func audioContext(bytes: Int) -> Int {
        min(1500, max(600, ((bytes + 31_999) / 32_000 + 1) * 50))
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

    private func server(for model: URL) -> WhisperServer {
        if let server = servers[model] { return server }
        let server = WhisperServer(config: config, model: model,
                                   port: model == config.fastModel ? config.fastPort : config.finalPort)
        servers[model] = server
        return server
    }

    /// Start outside Agents.sandboxed; a missing installation leaves the rest of the API usable.
    func startServers() async throws {
        guard FileManager.default.isExecutableFile(atPath: config.server.path),
              Self.regularNonempty(config.fastModel), Self.regularNonempty(config.finalModel) else {
            throw APIError(.notImplemented, "Run Runner/scripts/setup-whisper.sh.")
        }
        var failure: (any Error)?
        for model in Set([config.fastModel, config.finalModel]) {
            do { try await server(for: model).start() }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    func maintainServers() async {
        guard !stopping else { return }
        for server in servers.values { try? await server.start() }
    }

    func stopServers() async {
        stopping = true
        for server in servers.values { await server.shutdown() }
    }
}

/// One model per resident process. No Shell, credentials, files containing audio, or log pipes.
private actor WhisperServer {
    let config: Speech.Config
    let model: URL
    let port: Int
    let prefix = "/" + UUID().uuidString
    private var process: Process?
    private var busy = false
    private var closed = false

    init(config: Speech.Config, model: URL, port: Int) {
        self.config = config; self.model = model; self.port = port
    }

    deinit {
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    func shutdown() async {
        closed = true
        await stop()
    }

    private func stop() async {
        if let process, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            // waitUntilExit() inside the actor can sleep forever on macOS after the child is gone.
            while process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        }
        process = nil
    }

    func start() async throws {
        if process?.isRunning == true { return }
        guard !busy else { throw APIError(.serviceUnavailable, "This speech model is busy. Try again later.") }
        busy = true
        defer { busy = false }
        try await ensureStarted()
    }

    private func ensureStarted() async throws {
        guard !closed else { throw APIError(.serviceUnavailable, "The speech service is stopping.") }
        if process?.isRunning == true { return }
        guard (1...65535).contains(port), config.threads > 0 else {
            throw APIError(.notImplemented, "Invalid Whisper port or thread count.")
        }
        let child = Process()
        child.executableURL = config.server
        child.arguments = ["--model", model.path, "--threads", String(config.threads),
                           "--host", "127.0.0.1", "--port", String(port), "--request-path", prefix,
                           "--no-gpu", "--no-context", "--no-timestamps"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // No agent account, vault or CLI login environment reaches the server.
        child.environment = ["PATH": "/usr/bin:/bin"]
        try child.run()
        process = child
        let deadline = Date().addingTimeInterval(config.startupTimeout)
        do {
            while child.isRunning && Date() < deadline {
                if await ready(), child.isRunning {
                    if config.warmup {
                        // Initialize the short encoder/decoder graph before accepting speech.
                        // This is generated silence, never a recording from a device.
                        _ = try await infer(pcm: Data(repeating: 0, count: 32_000), language: "en", prompt: "",
                                            timeout: max(0.001, deadline.timeIntervalSinceNow))
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw APIError(.serviceUnavailable, "Whisper server did not become ready.")
        } catch {
            await stop()
            throw error
        }
    }

    private func ready() async -> Bool {
        guard let child = process, child.isRunning,
              let response = try? await WhisperConnection.request(pid: child.processIdentifier, port: port,
                  path: prefix + "/", timeout: 0.5) else { return false }
        return response.status == 200
    }

    func transcribe(pcm: Data, language: String, prompt: String) async throws -> Speech.Transcript {
        guard !busy else { throw APIError(.serviceUnavailable, "This speech model is busy. Try again later.") }
        busy = true
        defer { busy = false }
        do {
            try await ensureStarted()
            do { return try await infer(pcm: pcm, language: language, prompt: prompt) }
            catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost].contains(error.code) {
                // Exit notifications can lag behind socket closure. Inference is stateless;
                // retry once on a fresh owned server without appending PCM a second time.
                await stop()
                try await ensureStarted()
                return try await infer(pcm: pcm, language: language, prompt: prompt)
            }
        } catch {
            // Timeout/cancellation must release the model and its audio, including hung inference.
            await stop()
            throw APIError(.internalServerError, "Whisper failed or timed out.")
        }
    }

    private func infer(pcm: Data, language: String, prompt: String, timeout: Double? = nil) async throws -> Speech.Transcript {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("language", language)
        field("prompt", prompt)
        field("response_format", "verbose_json")
        field("no_language_probabilities", "true")
        field("no_context", "true")
        // Whisper otherwise pads every short utterance to a 30-second encoder window.
        // Keep at least 12 seconds, plus a second beyond the audio, and use the full
        // window for long utterances so whisper.cpp can process successive 30s blocks.
        field("audio_ctx", String(Speech.audioContext(bytes: pcm.count)))
        body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(Speech.wave(pcm))
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        guard let child = process, child.isRunning else { throw URLError(.cannotConnectToHost) }
        let response = try await WhisperConnection.request(pid: child.processIdentifier, port: port,
            path: prefix + "/inference", timeout: min(config.timeout, timeout ?? config.timeout),
            body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        struct Result: Decodable { let text: String; let language: String? }
        guard response.status == 200,
              let result = try? JSONDecoder().decode(Result.self, from: response.body) else {
            throw APIError(.internalServerError, "Whisper failed.")
        }
        return Speech.Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 language: ["english": "en", "portuguese": "pt"][result.language?.lowercased() ?? ""])
    }
}
