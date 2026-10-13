import Network
import Observation
import SwiftUI

/// Settings › Your Mac (#285): how this iPhone reaches the Mac, at home over the local network
/// and away through the Mac's tunnel (Shared/RemoteRoute.swift). Until pairing (#284) hands the
/// hostname over in a QR code, it's typed here from the Mac's Settings › Remote access.
struct ConnectScreen: View {
    @Environment(Phone.self) private var phone
    @State private var name = ""
    @State private var hostname = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if let link = phone.link {
                    LabeledContent("Mac", value: link.name)
                    LabeledContent("Hostname", value: link.hostname)
                    LabeledContent("Reached", value: phone.route?.label ?? "Not yet")
                    LabeledContent("Status", value: phone.connection.status(host: phone.host))
                    Button("Unlink", role: .destructive) { phone.link = nil }
                } else {
                    Text("No Mac linked yet: Oby talks to the runner at the address in Settings.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Mac")
            } footer: {
                Text("At home, Oby finds your Mac on the local network and talks to it directly. Away, it goes through the Mac's own Cloudflare Tunnel, at the hostname the Mac's Settings › Remote access shows. Nothing to open on your router.")
            }
            Section {
                TextField("Mac's name", text: $name, prompt: Text("As Sharing settings name it"))
                TextField("Hostname", text: $hostname, prompt: Text("oby-….tetrix.pro"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(link)
                Button("Link") { link() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || hostname.trimmingCharacters(in: .whitespaces).isEmpty)
                if let problem { Text(problem).foregroundStyle(.red) }
            } header: {
                Text("Link by hand")
            } footer: {
                Text("Pairing by QR code comes with the Mac's gateway. Until then, type what the Mac's Settings › Remote access shows.")
            }
        }
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = phone.link?.name ?? ""
            hostname = phone.link?.hostname ?? ""
        }
    }

    private func link() {
        guard let host = MacLink.hostname(from: hostname) else {
            problem = "The hostname looks like oby-….tetrix.pro, as the Mac's Settings › Remote access shows it."
            return
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            problem = "The Mac's name is what its Sharing settings call it."
            return
        }
        problem = nil
        Task { @MainActor in
            do { try await phone.pair(name: name, hostname: host) }
            catch { problem = error.localizedDescription }
        }
    }
}

/// Looks for the linked Mac's gateway on the local network: the gateway (#284) advertises
/// `_oby._tcp` under the Mac's name, and when that service is seen its address is resolved and
/// `found` gets the gateway's URL; nil once it's gone. Nothing is looked for without a name.
final class MacFinder {
    private var browser: NWBrowser?
    private var resolving: NWConnection?
    private var found: (URL?) -> Void = { _ in }
    private var current: URL?

    /// Starts looking for `name`'s service, or stops when there's none to look for.
    func find(named name: String?, found: @escaping (URL?) -> Void) {
        stop()
        self.found = found
        guard let name else {
            report(nil)
            return
        }
        let browser = NWBrowser(for: .bonjour(type: "_oby._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.seen(results, name: name) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.report(nil) } }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving?.cancel()
        resolving = nil
    }

    private func seen(_ results: Set<NWBrowser.Result>, name: String) {
        let mine = results.first { result in
            if case .service(let found, _, _, _) = result.endpoint { return found == name }
            return false
        }
        guard let mine else {
            report(nil)
            return
        }
        resolve(mine.endpoint)
    }

    /// Bonjour names a service, not an address: a connection to it resolves one, then ends.
    private func resolve(_ endpoint: NWEndpoint) {
        resolving?.cancel()
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        self?.report(RemoteRoute.lanURL(host: Self.text(host), port: Int(port.rawValue)))
                    }
                    connection.cancel()
                case .failed:
                    self?.report(nil)
                default:
                    break
                }
            }
        }
        resolving = connection
        connection.start(queue: .main)
    }

    private static func text(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        // A link-local address names its interface after %, which a URL can't carry.
        case .ipv6(let address): String("\(address)".split(separator: "%").first ?? "")
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }

    private func report(_ url: URL?) {
        guard url != current else { return }
        current = url
        found(url)
    }
}
