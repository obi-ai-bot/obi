import Foundation
import Testing

/// GitHub's CLI ships inside Oby.app (apps/mac/app/Tools/bundle-gh.sh, the owner's decision of
/// 2026-10-18): the pinned release, universal, signed with the app's identity and the hardened
/// runtime, beside the app's executable, where obid looks for it (core/crates/obid/src/github.rs).
struct BundledGitHubCLITests {
    @Test func ghIsBundledAndSigned() throws {
        let binary = try #require(Bundle.main.url(forAuxiliaryExecutable: "gh"))
        #expect(binary.path.hasSuffix("/Contents/MacOS/gh"))
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let verified = try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", binary.path])
        #expect(verified.status == 0, Comment(rawValue: "codesign --verify: \(verified.err)"))
        let details = try run("/usr/bin/codesign", ["-d", "-vv", binary.path])
        let directory = details.err.split(separator: "\n").first { $0.hasPrefix("CodeDirectory") } ?? ""
        #expect(directory.contains("runtime"), Comment(rawValue: "no hardened runtime: \(details.err)"))
        let slices = try run("/usr/bin/lipo", ["-archs", binary.path])
        #expect(slices.out.contains("arm64") && slices.out.contains("x86_64"), Comment(rawValue: slices.out))
        // No login is read: `--version` touches no config or Keychain.
        let version = try run(binary.path, ["--version"])
        #expect(version.out.contains("gh version 2.102.0"), Comment(rawValue: version.out))
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ["GH_NO_UPDATE_NOTIFIER": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }
}
