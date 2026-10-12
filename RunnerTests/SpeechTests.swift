import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import ObyEngine
@testable import oby_runner

@Suite(.serialized)
final class SpeechTests {
    let folder: URL
    var config: Speech.Config
    let device = UUID().uuidString
    let utterance = UUID().uuidString
    let chunk = Data(repeating: 0, count: 3200)

    init() throws {
        folder = try temporaryFolder()
        let cli = folder.appending(path: "whisper-server")
        // Record only arguments and sample counts, never the audio or transcript in a log.
        let fake = #"""
        #!/usr/bin/env python3
        import json, pathlib, sys, time, email.parser, email.policy
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        args = sys.argv[1:]
        def value(flag): return args[args.index(flag) + 1]
        root = pathlib.Path(__file__).parent
        with (root / 'launches').open('a') as log: log.write(value('--model') + '\n')
        while (root / 'mode').exists() and (root / 'mode').read_text() == 'no-ready': time.sleep(.01)
        if (root / 'mode').exists() and (root / 'mode').read_text() == 'late-bind': time.sleep(.3)
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(200 if self.path == value('--request-path') + '/' else 404)
                self.end_headers()
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                    ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + body)
                fields = {p.get_param('name', header='content-disposition'): p.get_payload(decode=True) for p in message.iter_parts()}
                mode = (root / 'mode').read_text() if (root / 'mode').exists() else ''
                # Started once it knows its mode: a test may take the mode away as soon as it sees this.
                (root / 'started').touch()
                if mode == 'hang':
                    while True: time.sleep(.01)
                if mode == 'block':
                    while (root / 'mode').exists(): time.sleep(.01)
                record = {'model': pathlib.Path(value('--model')).name, 'threads': value('--threads'),
                          'language': fields['language'].decode(), 'prompt': fields['prompt'].decode(),
                          'bytes': len(fields['file'])-44, 'cpu': '--no-gpu' in args,
                          'response_format': fields['response_format'].decode(), 'probabilities_disabled': fields['no_language_probabilities'].decode(), 'audio_ctx': fields['audio_ctx'].decode(), 'no_context': fields['no_context'].decode(), 'host': value('--host'), 'pid': __import__('os').getpid()}
                (root / 'args.json').write_text(json.dumps(record))
                self.send_response(500 if mode == 'fail' else 200)
                self.end_headers()
                self.wfile.write((json.dumps({'text': 'texto ' + str(len(fields['file'])-44) + '\n', 'language': 'portuguese' if mode == 'detect-pt' or fields['language'] == b'pt' else ('french' if mode == 'detect-other' else 'english')}) if mode not in ('fail', 'malformed') else 'private subprocess detail').encode())
        ThreadingHTTPServer((value('--host'), int(value('--port'))), Handler).serve_forever()
        """#
        try executable(fake, at: cli)
        let ports = try Self.availablePorts()
        config = Speech.Config(server: cli, fastModel: folder.appending(path: "fast.bin"),
                               finalModel: folder.appending(path: "large.bin"), folder: folder.appending(path: "audio"),
                               threads: 7, fastPort: ports.0, finalPort: ports.1, warmup: false, names: ["oby", "tetrix", "deskree-inc/repo"])
        try Data([1]).write(to: config.fastModel)
        try Data([1]).write(to: config.finalModel)
    }
    deinit { try? FileManager.default.removeItem(at: folder) }

    private static func availablePorts() throws -> (Int, Int) {
        func reserve() throws -> (Int32, Int) {
            #if os(Linux)
            let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            #if !os(Linux)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard bound == 0, named == 0 else {
                close(descriptor)
                throw CocoaError(.fileReadUnknown)
            }
            return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
        }
        let first = try reserve()
        defer { close(first.0) }
        let second = try reserve()
        defer { close(second.0) }
        return (first.1, second.1)
    }

    func record() throws -> [String: Any] { object(try Data(contentsOf: folder.appending(path: "args.json"))) }
    func clean() throws { #expect(!FileManager.default.fileExists(atPath: config.folder.path)) }
    func mode(_ mode: String) throws { try mode.write(to: folder.appending(path: "mode"), atomically: true, encoding: .utf8) }

    @Test func setupScriptReusesInstalledModels() async throws {
        let bin = folder.appending(path: "setup-tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = #"""
        #!/usr/bin/env python3
        import os, pathlib, sys
        tool = pathlib.Path(sys.argv[0]).name
        args = sys.argv[1:]
        root = pathlib.Path(os.environ['OBY_HOME'])
        if tool == 'git':
            if 'clone' in args: (pathlib.Path(args[-1]) / '.git').mkdir(parents=True)
            else: print('v1.8.2')
        elif tool == 'cmake':
            if '-B' in args:
                build = pathlib.Path(args[args.index('-B') + 1])
                (build / 'bin').mkdir(parents=True, exist_ok=True)
                (build / 'bin' / 'whisper-cli').write_text('#!/bin/sh\nexit 0\n')
                (build / 'bin' / 'whisper-server').write_text('#!/bin/sh\nexit 0\n')
                (root / 'cmake-flags').write_text(' '.join(args))
        elif tool == 'curl':
            pathlib.Path(args[args.index('--output') + 1]).write_bytes(b'model')
            with (root / 'downloads').open('a') as log: log.write('download\n')
        """#
        for tool in ["git", "cmake", "curl", "c++", "flock"] {
            try executable(stub, at: bin.appending(path: tool))
        }
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Runner/scripts/setup-whisper.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["OBY_HOME"] = folder.path
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        let setupEnvironment = environment
        for _ in 0..<2 {
            let code = try await Task.detached {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/bash")
                process.arguments = [script.path]
                process.environment = setupEnvironment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            #expect(code == 0)
        }
        let downloads = try String(contentsOf: folder.appending(path: "downloads"), encoding: .utf8)
        #expect(downloads == "download\ndownload\ndownload\n")
        #expect(FileManager.default.isExecutableFile(atPath: folder.appending(path: "whisper/bin/whisper-server").path))
        let flags = try String(contentsOf: folder.appending(path: "cmake-flags"), encoding: .utf8)
        #expect(flags.contains("-DGGML_NATIVE=ON") && flags.contains("-DBUILD_SHARED_LIBS=OFF"))
        #expect(flags.contains("-DGGML_CUDA=OFF") && flags.contains("-DGGML_METAL=OFF"))
    }

    @Test func environmentOverridesAndInvalidThreads() async throws {
        let settings = Speech.Config.environment(["OBY_WHISPER_SERVER": "/custom/cli",
            "OBY_WHISPER_FAST_MODEL": "/custom/fast", "OBY_WHISPER_FINAL_MODEL": "/custom/final",
            "OBY_WHISPER_THREADS": "8", "OBY_SPEECH_NAMES": "oby,tetrix,owner/repo"])
        #expect(settings.server.path == "/custom/cli" && settings.fastModel.path == "/custom/fast")
        #expect(settings.finalModel.path == "/custom/final" && settings.threads == 8)
        #expect(settings.names == ["oby", "tetrix", "owner/repo"])
        #expect(Speech.Config.environment([:]).threads == 8)
        #expect(Speech.Config.environment([:]).names == nil)
        #expect(Speech.Config.environment(["OBY_WHISPER_THREADS": "invalid"]).threads == 0)
        config.threads = 0
        let speech = Speech(config: config)
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .notImplemented)
    }

    @Test func promptUsesShortNamesAndBoundsOverrides() {
        config.names = nil
        #expect(config.prompt(repos: ["deskree-inc/oby", "owner/blok", "other/blok"]) == "oby, tetrix, blok")
        let long = config.prompt(repos: ["owner/" + String(repeating: "á", count: 1000)])
        #expect(long.hasPrefix("oby, tetrix, á"))
        #expect(long.utf8.count <= 512 && long.utf8.count >= 510)
        config.names = [" custom ", "custom", "owner/special"]
        #expect(config.prompt(repos: ["owner/ignored"]) == "custom, owner/special")
        config.names = [String(repeating: "á", count: 1000)]
        #expect(config.prompt(repos: []).utf8.count == 512)
    }

    @Test func partialAndFinalAccumulateAndChooseModels() async throws {
        let speech = Speech(config: config)
        let partial = try await speech.transcribe(device: device, utterance: utterance, audio: chunk, language: "pt")
        #expect(partial.text == "texto 3200" && !partial.final)
        var args = try record()
        #expect(args["model"] as? String == "fast.bin")
        #expect(args["threads"] as? String == "7")
        #expect(args["language"] as? String == "pt")
        #expect(args["prompt"] as? String == "oby, tetrix, deskree-inc/repo")
        #expect(args["cpu"] as? Bool == true)
        #expect(args["audio_ctx"] as? String == "600")
        try clean()
        let final = try await speech.transcribe(device: device, utterance: utterance, audio: Speech.wave(chunk), wav: true, final: true, language: "pt")
        #expect(final.text == "texto 6400" && final.final)
        args = try record()
        #expect(args["model"] as? String == "large.bin")
        try clean()
        let next = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(next.text == "texto 3200")
        #expect(try record()["language"] as? String == "auto")
    }

    @Test func residentModelIsReusedAndRestartsAfterDeath() async throws {
        let speech = Speech(config: config)
        try await speech.startServers()
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        let firstPID = try #require(record()["pid"] as? Int)
        #expect(try record()["host"] as? String == "127.0.0.1")
        #expect(try record()["no_context"] as? String == "true")
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        #expect(try record()["pid"] as? Int == firstPID)
        #expect(try String(contentsOf: folder.appending(path: "launches"), encoding: .utf8).split(separator: "\n").count == 2)
        _ = kill(Int32(firstPID), SIGKILL)
        try await Task.sleep(for: .milliseconds(100))
        await speech.maintainServers()
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        let newPID = try #require(record()["pid"] as? Int)
        #expect(newPID != firstPID)
        await speech.stopServers()
        #expect(kill(Int32(newPID), 0) == -1)
        try clean()
    }

    @Test func startupWarmsTheModelWithGeneratedSilenceAndReusesIt() async throws {
        config.finalModel = config.fastModel
        config.warmup = true
        let speech = Speech(config: config)
        try await speech.startServers()
        let args = try record()
        #expect(args["bytes"] as? Int == 32_000)
        #expect(args["audio_ctx"] as? String == "600")
        #expect(args["language"] as? String == "en")
        #expect(args["prompt"] as? String == "")
        let warmPID = try #require(args["pid"] as? Int)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk, final: true)
        #expect(try record()["pid"] as? Int == warmPID)
        #expect(try record()["bytes"] as? Int == chunk.count)
        await speech.stopServers()
        try clean()
    }

    @Test func oneServerForIdenticalModelsAndOccupiedPortsFailClosed() async throws {
        config.finalModel = config.fastModel
        let speech = Speech(config: config)
        try await speech.startServers()
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk, final: true)
        #expect(try String(contentsOf: folder.appending(path: "launches"), encoding: .utf8).split(separator: "\n").count == 1)
        config.startupTimeout = 1
        let other = Speech(config: config)
        await #expect(throws: APIError.self) { try await other.startServers() }
        // The existing server belongs to speech; the failed startup must not stop or use it.
        _ = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        await speech.stopServers()
        await other.stopServers()
    }

    @Test func portSquatterCannotReceiveWarmupOrSpeechDuringRestart() async throws {
        config.finalModel = config.fastModel
        // Python's start and the warmup can take seconds on a busy machine. The restarts that
        // must fail end on their own, when the server can't bind the squatter's port.
        config.startupTimeout = 30
        config.warmup = true
        let speech = Speech(config: config)
        try await speech.startServers()
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        let pid = try #require(record()["pid"] as? Int)
        _ = kill(Int32(pid), SIGKILL)
        try await Task.sleep(for: .milliseconds(100))
        // Each restart is probed against the squatter while it starts, then exits like a real
        // whisper-server whose port is taken.
        try mode("late-bind")
        let script = folder.appending(path: "squatter.py")
        // The impostor accepts every prefix, including ones it has never seen.
        // Record only whether a POST happened, never its body.
        try #"""
        import pathlib, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        root = pathlib.Path(__file__).parent
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
            def do_POST(self):
                (root / 'leaked-post').touch()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"text":"stolen","language":"english"}')
        server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler)
        (root / 'squatter-ready').touch()
        server.serve_forever()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let squatter = Process()
        squatter.executableURL = URL(filePath: "/usr/bin/python3")
        squatter.arguments = [script.path, String(config.fastPort)]
        squatter.standardOutput = FileHandle.nullDevice
        squatter.standardError = FileHandle.nullDevice
        try squatter.run()
        defer {
            if squatter.isRunning { _ = kill(squatter.processIdentifier, SIGKILL) }
        }
        for _ in 0..<3000 {
            if FileManager.default.fileExists(atPath: folder.appending(path: "squatter-ready").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "squatter-ready").path))
        await #expect(throws: APIError.self) { try await speech.startServers() }
        await #expect(throws: APIError.self) {
            try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk, final: true)
        }
        await speech.maintainServers()
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "leaked-post").path))
        _ = kill(squatter.processIdentifier, SIGKILL)
        while squatter.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        try await speech.startServers()
        let recovered = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(recovered.text == "texto 3200")
        await speech.stopServers()
        try clean()
    }

    @Test func startupHasDeadline() async throws {
        config.startupTimeout = 0.2
        try mode("no-ready")
        let speech = Speech(config: config)
        await #expect(throws: APIError.self) { try await speech.startServers() }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
        await speech.stopServers()
        try clean()
    }

    @Test func malformedServerResponseDiscardsUtterance() async throws {
        try mode("malformed")
        let speech = Speech(config: config)
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .internalServerError)
        #expect(error?.message.contains("private") == false)
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        _ = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        try clean()
    }

    @Test func encoderWindowCoversTheAudioAndPreservesLongUtterances() {
        #expect(Speech.audioContext(bytes: 32_000) == 600)
        #expect(Speech.audioContext(bytes: 11 * 32_000) == 600)
        #expect(Speech.audioContext(bytes: 11 * 32_000 + 2) == 650)
        #expect(Speech.audioContext(bytes: 20 * 32_000) == 1050)
        #expect(Speech.audioContext(bytes: 30 * 32_000) == 1500)
        #expect(Speech.audioContext(bytes: Speech.maxBytes) == 1500)
    }

    @Test func finalReusesLatestDetectedLanguageFromSufficientPartialAudio() async throws {
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: Data(repeating: 0, count: 160_000))
        #expect(try record()["language"] as? String == "auto")
        // A later partial can correct the detected language; it still performs detection.
        try mode("detect-pt")
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        #expect(try record()["language"] as? String == "auto")
        let answer = try await speech.transcribe(device: device, utterance: utterance, audio: Data(), final: true)
        #expect(answer.text == "texto 163200")
        #expect(try record()["language"] as? String == "pt")
        #expect(try record()["response_format"] as? String == "verbose_json")
        #expect(try record()["probabilities_disabled"] as? String == "true")
        _ = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(try record()["language"] as? String == "auto")
        await speech.stopServers()
    }

    @Test func shortOrOtherLanguagePartialsKeepAutomaticFinalDetection() async throws {
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: Data(), final: true)
        #expect(try record()["language"] as? String == "auto")
        try mode("detect-other")
        let next = UUID().uuidString
        _ = try await speech.transcribe(device: device, utterance: next, audio: Data(repeating: 0, count: 160_000))
        _ = try await speech.transcribe(device: device, utterance: next, audio: Data(), final: true)
        #expect(try record()["language"] as? String == "auto")
        await speech.stopServers()
    }

    @Test func onlyOneUtterancePerDeviceAndEmptyFinalWorks() async throws {
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: UUID().uuidString, audio: self.chunk) }
        await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk, language: "en") }
        let final = try await speech.transcribe(device: device, utterance: utterance, audio: Data(), final: true)
        #expect(final.text == "texto 3200")
    }

    @Test func sixtySecondLimitDiscardsAudio() async throws {
        let speech = Speech(config: config)
        for _ in 0..<6 {
            _ = try await speech.transcribe(device: device, utterance: utterance, audio: Data(repeating: 0, count: 320_000))
        }
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: Data([0, 0])) }
        #expect(error?.status == .contentTooLarge)
        let next = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(next.text == "texto 3200")
        try clean()
    }

    @Test func missingServerOrEitherModelIs501() async throws {
        for url in [config.server, config.fastModel, config.finalModel] {
            let data = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            let speech = Speech(config: config)
            let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
            #expect(error?.status == .notImplemented)
            #expect(error?.message.contains("setup-whisper.sh") == true)
            try data.write(to: url)
            if url == config.server { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        }
    }

    @Test func emptyModelsAre501() async throws {
        try Data().write(to: config.finalModel)
        let speech = Speech(config: config)
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .notImplemented)
    }

    @Test func failuresCleanAndDiscardBeforeRetry() async throws {
        try mode("fail")
        let speech = Speech(config: config)
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .internalServerError)
        #expect(error?.message.contains("private subprocess detail") == false)
        try clean()
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        let next = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(next.text == "texto 3200")
        try clean()
    }

    @Test func timeoutsCleanAndReleaseTheDevice() async throws {
        config.timeout = 0.25
        try mode("hang")
        let speech = Speech(config: config)
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .internalServerError)
        try clean()
        // A fresh utterance reaches audio validation (400), proving the old session and busy
        // flag were removed (either would return 409). No fast successful CLI deadline race.
        let next = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: UUID().uuidString, audio: Data([1])) }
        #expect(next?.status == .badRequest)
    }

    @Test func simultaneousCallsConflictWhileOtherDeviceWorks() async throws {
        try mode("block")
        let speech = Speech(config: config)
        let first = Task { try await speech.transcribe(device: device, utterance: utterance, audio: chunk) }
        for _ in 0..<3000 {
            if FileManager.default.fileExists(atPath: folder.appending(path: "started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .conflict)
        let busy = await #expect(throws: APIError.self) { try await speech.transcribe(device: UUID().uuidString, utterance: UUID().uuidString, audio: self.chunk) }
        #expect(busy?.status == .serviceUnavailable)
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        _ = try await speech.transcribe(device: UUID().uuidString, utterance: UUID().uuidString, audio: chunk, final: true)
        _ = try await first.value
        try clean()
    }

    @Test func busyModelRejectsChunkWithoutLosingOrDuplicatingEarlierAudio() async throws {
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        try FileManager.default.removeItem(at: folder.appending(path: "started"))
        try mode("block")
        let blocking = Task { try await speech.transcribe(device: UUID().uuidString, utterance: UUID().uuidString, audio: chunk) }
        for _ in 0..<3000 {
            if FileManager.default.fileExists(atPath: folder.appending(path: "started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
        let error = await #expect(throws: APIError.self) {
            try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk)
        }
        #expect(error?.status == .serviceUnavailable)
        let newDevice = UUID().uuidString
        let freshBusy = await #expect(throws: APIError.self) {
            try await speech.transcribe(device: newDevice, utterance: UUID().uuidString, audio: self.chunk)
        }
        #expect(freshBusy?.status == .serviceUnavailable)
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        _ = try await blocking.value
        let retry = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        #expect(retry.text == "texto 6400")
        let final = try await speech.transcribe(device: device, utterance: utterance, audio: Data(), final: true)
        #expect(final.text == "texto 6400")
        let fresh = try await speech.transcribe(device: newDevice, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(fresh.text == "texto 3200")
        await speech.stopServers()
        try clean()
    }

    @Test func restartingModelRejectsChunkAndPreservesUtterance() async throws {
        config.finalModel = config.fastModel
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        let pid = try #require(record()["pid"] as? Int)
        _ = kill(Int32(pid), SIGKILL)
        try await Task.sleep(for: .milliseconds(100))
        try mode("no-ready")
        let restarting = Task { await speech.maintainServers() }
        for _ in 0..<3000 {
            let launches = try String(contentsOf: folder.appending(path: "launches"), encoding: .utf8)
            if launches.split(separator: "\n").count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: folder.appending(path: "launches"), encoding: .utf8).split(separator: "\n").count >= 2)
        let error = await #expect(throws: APIError.self) {
            try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk, final: true)
        }
        #expect(error?.status == .serviceUnavailable)
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        await restarting.value
        let retry = try await speech.transcribe(device: device, utterance: utterance, audio: chunk, final: true)
        #expect(retry.text == "texto 6400")
        await speech.stopServers()
        try clean()
    }

    @Test func idleExpiryAndStartupRemoveAbandonedAudio() async throws {
        config.idleTimeout = 0.02
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        // The device's next utterance conflicts until the idle expiry runs, which a busy machine may delay.
        var next = try? await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        for _ in 0..<500 where next == nil {
            try await Task.sleep(for: .milliseconds(10))
            next = try? await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        }
        #expect(next?.text == "texto 3200")
        try FileManager.default.createDirectory(at: config.folder, withIntermediateDirectories: true)
        try chunk.write(to: config.folder.appending(path: "leftover.wav"))
        try await speech.discardAbandonedAudio()
        #expect(!FileManager.default.fileExists(atPath: config.folder.path))
    }

    @Test func invalidWAVAndOddPCMNeverReachServer() async throws {
        let speech = Speech(config: config)
        var badRate = Speech.wave(chunk); badRate[24] = 0
        var stereo = Speech.wave(chunk); stereo[22] = 2
        var float = Speech.wave(chunk); float[20] = 3
        var truncated = Speech.wave(chunk); truncated.removeLast()
        for audio in [badRate, stereo, float, truncated, Data("RIFF".utf8)] {
            let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: audio, wav: true) }
            #expect(error?.status == .badRequest)
        }
        await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: Data([1])) }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
    }

    @MainActor @Test func endpointIsOwnerGatedAndValidatesBinaryRequests() async throws {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby", "owner/blok"]
        config.names = nil
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")), speech: Speech(config: config))
        let app = Application(router: api.router(owner: "owner"))
        let uri = "/v1/speech?device=\(device)&utterance=\(utterance)&final=true&language=en"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .post, body: ByteBuffer(bytes: chunk)) { #expect($0.status == .unauthorized) }
            let owner: HTTPFields = [.tailscaleUserLogin: "owner", .contentType: "audio/pcm"]
            try await client.execute(uri: uri, method: .post, headers: owner, body: ByteBuffer(bytes: chunk)) {
                #expect($0.status == .ok)
                let answer = object(Data($0.body.readableBytesView))
                #expect(answer["text"] as? String == "texto 3200")
                #expect(answer["final"] as? Bool == true)
            }
            #expect(try record()["prompt"] as? String == "oby, tetrix, blok")
            await MainActor.run { desk.repos = ["owner/updated"] }
            try await client.execute(uri: uri, method: .post, headers: owner, body: ByteBuffer(bytes: chunk)) {
                #expect($0.status == .ok)
            }
            #expect(try record()["prompt"] as? String == "oby, tetrix, updated")
            for bad in ["/v1/speech", uri.replacingOccurrences(of: "language=en", with: "language=xx")] {
                try await client.execute(uri: bad, method: .post, headers: owner, body: ByteBuffer(bytes: chunk)) { #expect($0.status == .badRequest) }
            }
            try await client.execute(uri: uri, method: .post, headers: [.tailscaleUserLogin: "owner", .contentType: "audio/mp4"], body: ByteBuffer(bytes: chunk)) { #expect($0.status == .unsupportedMediaType) }
            try await client.execute(uri: uri, method: .post, headers: owner, body: ByteBuffer(bytes: Data(repeating: 0, count: Speech.chunkBytes + 1))) { #expect($0.status == .contentTooLarge) }
        }
    }
}
