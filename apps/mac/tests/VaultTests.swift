import Foundation
import Testing
@testable import Oby

/// The Mac's vault in the real keychain, under a service of its own that the test removes.
struct KeychainVaultTests {
    @Test func savesListsByNameAndRemoves() throws {
        let store = KeychainVault(service: "com.deskree.oby.vault.tests-\(UUID().uuidString)")
        let vault = Vault(store: store)
        let value = "tok/\(UUID().uuidString)+a=b"
        defer { for name in (try? store.names()) ?? [] { try? store.remove(name) } }

        #expect(try vault.names().isEmpty)
        try vault.add(value, as: "staging-api-key")
        try vault.add("another-value-1234", as: "npm-token")
        #expect(try vault.names() == ["npm-token", "staging-api-key"])
        #expect(try vault.use("staging-api-key") { $0 } == value)
        // Saving again replaces it.
        try vault.add("replaced-value-5678", as: "staging-api-key")
        #expect(try store.value("staging-api-key") == "replaced-value-5678")
        #expect(try Publish.matches("x \(Data("replaced-value-5678".utf8).base64EncodedString())", leaks: vault.leaks())
                == ["vault secret staging-api-key, base64"])
        try vault.remove("staging-api-key")
        #expect(try vault.names() == ["npm-token"])
        #expect(try store.value("staging-api-key") == nil)
    }

    /// On the Mac too, a log line goes to OSLog with the vault's secrets taken out: `Logger` is Oby's own.
    @Test func theMacsLogLeavesSecretsOut() throws {
        let store = KeychainVault(service: "com.deskree.oby.vault.tests-\(UUID().uuidString)")
        let vault = Vault(store: store)
        defer { for name in (try? store.names()) ?? [] { try? store.remove(name) } }
        let value = "tok/\(UUID().uuidString)+a=b"
        try vault.add(value, as: "staging-api-key")
        #expect(Logger.jobs.text("gh said 401 for \(value, privacy: .public)", vault: vault) == "gh said 401 for [vault: staging-api-key]")
    }
}
