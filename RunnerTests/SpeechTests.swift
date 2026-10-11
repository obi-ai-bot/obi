import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
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
        let cli = folder.appending(path: "whisper-cli")
        // Record only arguments and sample counts, never the audio or transcript in a log.
        let fake = #"""
        #!/usr/bin/env python3
        import json, pathlib, sys, time
        args = sys.argv[1:]
        def value(flag): return args[args.index(flag) + 1]
        root = pathlib.Path(__file__).parent
        (root / 'started').touch()
        mode = (root / 'mode').read_text() if (root / 'mode').exists() else ''
        if mode == 'hang':
            while True: time.sleep(.01)
        if mode == 'block':
            while (root / 'mode').exists(): time.sleep(.01)
        if mode == 'fail':
            print('private subprocess detail', file=sys.stderr)
            sys.exit(1)
        audio = pathlib.Path(value('--file')).read_bytes()
        record = {'model': pathlib.Path(value('--model')).name, 'threads': value('--threads'),
                  'language': value('--language'), 'prompt': value('--prompt'), 'bytes': len(audio)-44,
                  'cpu': '--no-gpu' in args}
        (root / 'args.json').write_text(json.dumps(record))
        pathlib.Path(value('--output-file') + '.txt').write_text('texto ' + str(len(audio)-44) + '\n')
        """#
        try fake.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        config = Speech.Config(cli: cli, fastModel: folder.appending(path: "fast.bin"),
                               finalModel: folder.appending(path: "large.bin"), folder: folder.appending(path: "audio"),
                               threads: 7, names: ["oby", "tetrix", "deskree-inc/repo"])
        try Data([1]).write(to: config.fastModel)
        try Data([1]).write(to: config.finalModel)
    }
    deinit { try? FileManager.default.removeItem(at: folder) }

    func record() throws -> [String: Any] { object(try Data(contentsOf: folder.appending(path: "args.json"))) }
    func clean() throws { #expect(try FileManager.default.contentsOfDirectory(atPath: config.folder.path).isEmpty) }
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
                (root / 'cmake-flags').write_text(' '.join(args))
        elif tool == 'curl':
            pathlib.Path(args[args.index('--output') + 1]).write_bytes(b'model')
            with (root / 'downloads').open('a') as log: log.write('download\n')
        """#
        for tool in ["git", "cmake", "curl", "c++", "flock"] {
            let path = bin.appending(path: tool)
            try stub.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
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
        #expect(downloads == "download\ndownload\n")
        #expect(FileManager.default.isExecutableFile(atPath: folder.appending(path: "whisper/bin/whisper-cli").path))
        let flags = try String(contentsOf: folder.appending(path: "cmake-flags"), encoding: .utf8)
        #expect(flags.contains("-DGGML_NATIVE=ON") && flags.contains("-DBUILD_SHARED_LIBS=OFF"))
        #expect(flags.contains("-DGGML_CUDA=OFF") && flags.contains("-DGGML_METAL=OFF"))
    }

    @Test func environmentOverridesAndInvalidThreads() async throws {
        let settings = Speech.Config.environment(["OBY_WHISPER_CLI": "/custom/cli",
            "OBY_WHISPER_FAST_MODEL": "/custom/fast", "OBY_WHISPER_FINAL_MODEL": "/custom/final",
            "OBY_WHISPER_THREADS": "8", "OBY_SPEECH_NAMES": "oby,tetrix,owner/repo"])
        #expect(settings.cli.path == "/custom/cli" && settings.fastModel.path == "/custom/fast")
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

    @Test func missingCLIOrEitherModelIs501() async throws {
        for url in [config.cli, config.fastModel, config.finalModel] {
            let data = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            let speech = Speech(config: config)
            let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
            #expect(error?.status == .notImplemented)
            #expect(error?.message.contains("setup-whisper.sh") == true)
            try data.write(to: url)
            if url == config.cli { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
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
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: folder.appending(path: "started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
        let error = await #expect(throws: APIError.self) { try await speech.transcribe(device: self.device, utterance: self.utterance, audio: self.chunk) }
        #expect(error?.status == .conflict)
        try FileManager.default.removeItem(at: folder.appending(path: "mode"))
        _ = try await speech.transcribe(device: UUID().uuidString, utterance: UUID().uuidString, audio: chunk, final: true)
        _ = try await first.value
        try clean()
    }

    @Test func idleExpiryAndStartupRemoveAbandonedAudio() async throws {
        config.idleTimeout = 0.02
        let speech = Speech(config: config)
        _ = try await speech.transcribe(device: device, utterance: utterance, audio: chunk)
        try await Task.sleep(for: .milliseconds(100))
        let next = try await speech.transcribe(device: device, utterance: UUID().uuidString, audio: chunk, final: true)
        #expect(next.text == "texto 3200")
        try chunk.write(to: config.folder.appending(path: "leftover.wav"))
        try await speech.discardAbandonedAudio()
        #expect(!FileManager.default.fileExists(atPath: config.folder.path))
    }

    @Test func invalidWAVAndOddPCMNeverReachCLI() async throws {
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
