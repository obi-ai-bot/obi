import _CryptoExtras
import Foundation
@testable import ObyEngine

/// The Oby by Deskree app from the runner's settings (`OBY_GITHUB_APP_ID`, and the private key at
/// `OBY_GITHUB_APP_KEY` or `~/.config/oby/github-app.pem`). The key is read once, into the
/// signer, and never logged: what goes wrong is said by its path.
nonisolated enum GitHubAppKey {
    /// The app, nil when no App ID is set (then the owner's login does everything, as before), or
    /// why it can't be used.
    static func load(_ environment: [String: String]) -> Result<GitHubApp, Shell.Failure>? {
        guard let id = environment[GitHubApp.idVariable]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        let file = environment[GitHubApp.keyVariable].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? GitHubApp.defaultKey
        var info = stat()
        guard stat(file.path, &info) == 0 else { return .failure(Shell.Failure(message: "there's no key at \(file.path)")) }
        guard info.st_uid == getuid() else { return .failure(Shell.Failure(message: "\(file.path) belongs to another user: only the runner's user may own it")) }
        guard info.st_mode & 0o077 == 0 else {
            return .failure(Shell.Failure(message: "others may read \(file.path) (mode \(String(info.st_mode & 0o777, radix: 8))): run chmod 600 on it"))
        }
        let sign: @Sendable (Data) throws -> Data
        do {
            sign = try signer(pem: String(contentsOf: file, encoding: .utf8))
        } catch {
            return .failure(Shell.Failure(message: "\(file.path) isn't an RSA private key in PEM"))
        }
        return .success(GitHubApp(id: id, sign: sign))
    }

    /// RS256 with the key in `pem`: RSASSA-PKCS1-v1_5 over SHA-256.
    static func signer(pem: String) throws -> @Sendable (Data) throws -> Data {
        let key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        return { Data(try key.signature(for: $0, padding: .insecurePKCS1v1_5).rawRepresentation) }
    }
}
