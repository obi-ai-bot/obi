import Network
import Observation
import SwiftUI
import VisionKit

/// Settings › Your Mac (#285): how this iPhone reaches the Mac, at home over the local network
/// and away through the Mac's tunnel (Shared/RemoteRoute.swift). Until pairing (#284) hands the
/// hostname, one-time secret and gateway key over the Mac's pairing QR code.
struct ConnectScreen: View {
    @Environment(Phone.self) private var phone
    @State private var problem: String?
    @State private var scanning = false

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
                    Button("Scan Mac pairing QR") { scanning = true }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            } header: {
                Text("Your Mac")
            } footer: {
                Text("At home, Oby finds your Mac on the local network and talks to it directly. Away, it goes through the Mac's own Cloudflare Tunnel, at the hostname the Mac's Settings › Remote access shows. Nothing to open on your router.")
            }
        }
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) { PairingQRScanner { text in scan(text) } }
    }

    private func scan(_ text: String) {
        scanning = false
        Task { @MainActor in
            do {
                let qr = try JSONDecoder().decode(PairingQR.self, from: Data(text.utf8))
                try await phone.pair(qr)
                problem = nil
            }
            catch { problem = error.localizedDescription }
        }
    }
}

/// The Mac QR contains the hostname, one-time secret and the gateway key. Decode it on the
/// phone and let Phone.pair pin the key before saving the link.
private struct PairingQRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .accurate,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true,
                                                isGuidanceEnabled: true,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var didFind = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard !didFind, case .barcode(let barcode) = item,
                  let text = barcode.payloadStringValue else { return }
            didFind = true
            dataScanner.stopScanning()
            found(text)
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
