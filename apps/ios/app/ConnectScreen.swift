import AVFoundation
import Network
import Observation
import SwiftUI
import UIKit

/// Settings › Your Mac (#285, #284): how this iPhone reaches the Mac, at home over the local
/// network and away through the Mac's tunnel (apps/shared/RemoteRoute.swift), and how it pairs: the QR
/// code the Mac's Settings › Runner shows, or its six-digit code typed here with the Mac picked
/// from those Bonjour finds on this network. Either buys the device token every gateway request
/// carries (apps/ios/app/Phone.swift, GatewayTokenStore). A hostname alone cannot authorize the gateway.
struct ConnectScreen: View {
    @Environment(Phone.self) private var phone
    @State private var name = ""
    @State private var hostname = ""
    @State private var problem: String?
    @State private var scanning = false
    @State private var enteringCode = false
    @State private var code = ""
    @State private var chosenMac = ""
    @State private var pairing = false
    @State private var paired: String?
    @State private var browser = MacBrowser()

    var body: some View {
        Form {
            Section {
                if let link = phone.link {
                    LabeledContent("Mac", value: link.name)
                    LabeledContent("Hostname", value: link.hostname)
                    LabeledContent("Reached", value: phone.route?.label ?? "Not yet")
                    LabeledContent("Status", value: phone.connection.status(host: phone.host))
                    LabeledContent("Device token", value: GatewayTokenStore.read() == nil ? "None: pair below" : "In the keychain")
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
                Button("Scan QR code") { scanning = true }
                // The QR code's text, copied from wherever the Mac's invitation was sent: pairing
                // from away, with no Mac screen to scan.
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    Task { await pair(value) }
                }
                Button(enteringCode ? "Hide code entry" : "Enter code") { enteringCode.toggle() }
                if enteringCode {
                    TextField("Six-digit code", text: $code, prompt: Text("123456"))
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                    if browser.names.isEmpty {
                        LabeledContent("Mac", value: "Looking on this network…")
                    } else {
                        Picker("Mac", selection: $chosenMac) {
                            ForEach(browser.names, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button(pairing ? "Pairing…" : "Pair") { Task { await pairWithCode() } }
                        .disabled(pairing || PairingCode.normalized(code) == nil || chosenMac.isEmpty)
                }
                if let paired { Text(paired).foregroundStyle(.secondary) }
                if let problem { Text(problem).foregroundStyle(.red) }
            } header: {
                Text("Pair with your Mac")
            } footer: {
                Text("On the Mac, Settings › Runner › Pair a device shows a QR code and a six-digit code, good for two minutes and once. On the local network, pairing is plain HTTP plus the device token this iPhone keeps in its keychain; away from home, the Mac's tunnel carries it.")
            }
            Section {
                TextField("Mac's name", text: $name, prompt: Text("As Sharing settings name it"))
                TextField("Hostname", text: $hostname, prompt: Text("oby-….tetrix.pro"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(link)
                Button("Save Mac name") { link() }
                    .disabled(!canSaveMacName)
            } header: {
                Text("Link by hand")
            } footer: {
                Text("Pair with the QR code or six-digit code first. The tunnel and local network both require the device token pairing stores in this iPhone's keychain. This form can update the name for the same paired Mac.")
            }
        }
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = phone.link?.name ?? ""
            hostname = phone.link?.hostname ?? ""
            chosenMac = phone.link?.name ?? ""
        }
        .onChange(of: enteringCode) { _, entering in
            if entering { browser.start() } else { browser.stop() }
        }
        .onChange(of: browser.names) { _, names in
            if chosenMac.isEmpty || !names.contains(chosenMac) { chosenMac = names.first ?? "" }
        }
        .onDisappear { browser.stop() }
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                scanning = false
                Task { await pair(value) }
            }
        }
    }

    private func link() {
        guard GatewayTokenStore.read() != nil, let pairedLink = phone.link else {
            problem = "Pair with the Mac's QR code or six-digit code before linking it here."
            return
        }
        guard let host = MacLink.hostname(from: hostname) else {
            problem = "The hostname looks like oby-….tetrix.pro, as the Mac's Settings › Remote access shows it."
            return
        }
        guard pairedLink.hostname == host else {
            problem = "Pair with that Mac first. A hostname alone can't authorize the gateway."
            return
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            problem = "The Mac's name is what its Sharing settings call it."
            return
        }
        problem = nil
        phone.link = MacLink(name: name, hostname: host)
    }

    private var canSaveMacName: Bool {
        guard GatewayTokenStore.read() != nil, let pairedLink = phone.link,
              let host = MacLink.hostname(from: hostname) else { return false }
        return pairedLink.hostname == host && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the QR code said: the gateway's URL, the Mac's link and the one-time secret.
    private func pair(_ value: String) async {
        do {
            let envelope = try GatewayEnvelope.decode(value)
            try await phone.pairGateway(url: envelope.url, credential: envelope.secret, link: envelope.link)
            linked(envelope.link.name)
        } catch { problem = error.localizedDescription }
    }

    /// The six digits typed, redeemed at the chosen Mac's gateway, found over Bonjour.
    private func pairWithCode() async {
        pairing = true
        defer { pairing = false }
        do {
            guard let digits = PairingCode.normalized(code) else {
                problem = "The code is the six digits the Mac shows."
                return
            }
            let mac = chosenMac
            guard !mac.isEmpty else {
                problem = "Pick the Mac on this network."
                return
            }
            guard let url = await MacFinder.resolve(named: mac) else {
                throw RunnerError(message: "\(mac) wasn't found on this network. Make sure the Mac is awake and on the same Wi-Fi, then try again.")
            }
            try await phone.pairGateway(url: url, credential: digits)
            code = ""
            enteringCode = false
            linked(mac)
        } catch { problem = error.localizedDescription }
    }

    private func linked(_ mac: String) {
        name = phone.link?.name ?? mac
        hostname = phone.link?.hostname ?? ""
        problem = nil
        paired = "Paired with \(mac). The device token is in this iPhone's keychain."
    }
}

/// What the Mac's pairing QR code carries (apps/mac/app/PairingView.swift): the gateway's URL, the Mac's
/// link (its name and tunnel hostname) and the one-time secret.
struct GatewayEnvelope: Decodable, Equatable {
    var url: URL
    var link: MacLink
    var secret: String

    static func decode(_ text: String) throws -> GatewayEnvelope {
        do {
            return try JSONDecoder().decode(GatewayEnvelope.self, from: Data(text.utf8))
        } catch {
            throw RunnerError(message: "That isn't Oby's pairing QR code. Scan the one the Mac's Settings › Runner shows.")
        }
    }
}

/// The six-digit fallback the Mac shows beside its QR code, as typed: spaces and dashes between
/// the digits are fine, anything else isn't.
enum PairingCode {
    static func normalized(_ text: String) -> String? {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 6, text.allSatisfy({ $0.isASCII && $0.isNumber || $0 == " " || $0 == "-" }) else { return nil }
        return digits
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(delegate: context.coordinator)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            found(value)
        }
    }
}

/// Every Mac advertising a gateway (`_oby._tcp`) on this network, by name, for Enter code.
@Observable
final class MacBrowser {
    private(set) var names: [String] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_oby._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }.sorted()
            Task { @MainActor in self?.names = names }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        names = []
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

    /// The gateway URL of the Mac named `name` on this network, once: nil when it isn't seen
    /// within `seconds`.
    static func resolve(named name: String, within seconds: Double = 10) async -> URL? {
        let finder = MacFinder()
        defer { finder.stop() }
        let urls = AsyncStream<URL?> { continuation in
            finder.find(named: name) { continuation.yield($0) }
        }
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await url in urls where url != nil { return url }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
