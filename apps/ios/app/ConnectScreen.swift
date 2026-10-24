import AVFoundation
import Network
import Observation
import SwiftUI
import UIKit

/// Connect (docs/ios-design.md "Connect", onboarding.md iPhone 1): the first screen until this
/// iPhone pairs, and Settings › Your Mac after. Oby, "Connect to your Mac", where the Mac shows its
/// code; the QR code first ("Scan the code"), then the Macs Bonjour finds on this network and the
/// six digits typed for one, or an invitation pasted from a message. Either buys the device token
/// every gateway request carries (Phone.swift, GatewayTokenStore); a hostname alone can't.
struct ConnectScreen: View {
    @Environment(Phone.self) private var phone
    @State private var problem: String?
    @State private var scanning = false
    @State private var code = ""
    @State private var chosenMac = ""
    @State private var pairing = false
    @State private var browser = MacBrowser()
    @State private var unpairing = false
    @State private var address = ""
    @State private var another = false
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ObyMark(size: 112).padding(.top, 24).accessibilityHidden(true)
                Text("Connect to your Mac").font(Tokens.font(22, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.top, 20).accessibilityAddTraits(.isHeader)
                Text("Oby on your Mac shows a code to pair with: Settings › Runner › Pair a device.")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
                    .padding(.top, 8)
                if let link = phone.link, !phone.needsPairing { paired(link).padding(.top, 24) }
                PrimaryButton(title: "Scan the code") { problem = nil; scanning = true }.padding(.top, 24)
                // The QR code's text, sent from wherever the Mac is: pairing from away.
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    Task { await pair(value) }
                }
                .buttonBorderShape(.capsule).tint(Tokens.pill).foregroundStyle(Tokens.item)
                .padding(.top, 10)
                onThisNetwork.padding(.top, 28)
                if let problem {
                    SetAbout(problem, color: Tokens.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }
                anotherRunner.padding(.top, 28)
            }
            .padding(.horizontal, Tokens.gutter).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.settingsCards, true)
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            browser.start()
            chosenMac = phone.link?.name ?? ""
            address = phone.runnerURL?.absoluteString ?? ""
            another = phone.runnerURL != nil
        }
        .onDisappear { browser.stop() }
        .onChange(of: browser.names) { _, names in
            if chosenMac.isEmpty || !names.contains(chosenMac) { chosenMac = names.first ?? "" }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                scanning = false
                Task { await pair(value) }
            }
        }
        .confirmationDialog("Unpair from \(phone.link?.name ?? "your Mac")?", isPresented: $unpairing, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { phone.link = nil }
        } message: {
            Text("This iPhone forgets its device token. Scan the code on your Mac to connect again.")
        }
    }

    /// The Mac this iPhone is paired with: how it's reached, until when, and Unpair.
    private func paired(_ link: MacLink) -> some View {
        SetGroup("Your Mac") {
            SetRow(link.name, about: [phone.route?.label, phone.pairedUntil.map { "Paired until \($0.formatted(.dateTime.month(.abbreviated).day()))" }]
                .compactMap(\.self).joined(separator: " · ")) {
                SetValue(phone.notice?.title ?? (phone.connection == .live ? "Connected" : "Connecting…"), connected: phone.connection == .live)
            }
            SetRow("Unpair", about: "Pair again with a new code.") {
                Button("Unpair", role: .destructive) { unpairing = true }.buttonStyle(.set)
            }
        }
    }

    /// The Macs on this network, and the six digits for the one picked.
    private var onThisNetwork: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetGroup("On this network", footer: "A code works once, for two minutes. This iPhone then stays paired for 30 days.") {
                if browser.names.isEmpty {
                    SetRow("Looking for Oby on this network…", quiet: true)
                }
                ForEach(browser.names, id: \.self) { name in
                    Button { chosenMac = name } label: {
                        SetRow(name) {
                            if name == chosenMac { Image(systemName: "checkmark").font(Tokens.font(13, .semibold)).foregroundStyle(Tokens.ink) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(name == chosenMac ? .isSelected : [])
                }
            }
            DigitBoxes(code: $code, typing: $typing)
            PrimaryButton(title: pairing ? "Connecting…" : "Connect") { Task { await pairWithCode() } }
                .disabled(pairing || PairingCode.normalized(code) == nil || chosenMac.isEmpty)
                .opacity(pairing || PairingCode.normalized(code) == nil || chosenMac.isEmpty ? 0.3 : 1)
                .padding(.top, 16)
        }
    }

    /// A runner that isn't a Mac (one on a server you run), by its address: folded away, as most
    /// people pair their Mac (docs/oby-ux.md row 33: no address field in Settings any more).
    private var anotherRunner: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Tokens.warm) { another.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("Another runner")
                    Image(systemName: "chevron.right").font(Tokens.font(10, .semibold)).rotationEffect(.degrees(another ? 90 : 0))
                }
                .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .accessibilityValue(another ? "Open" : "Folded")
            if another {
                SetGroup(footer: "For a runner on a server of yours, not your Mac. Clear it to use only your Mac.") {
                    SetRow("Address") {
                        SetField("Address", text: $address, prompt: "https://…", width: 200)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .onSubmit(saveAddress)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveAddress() {
        let typed = address.trimmingCharacters(in: .whitespaces)
        // Cleared: no runner but a paired Mac.
        if typed.isEmpty { problem = nil; phone.runnerURL = nil; return }
        guard let url = URL(string: typed), url.scheme == "https" else {
            problem = "The runner's address starts with https://"
            return
        }
        problem = nil
        if url != phone.runnerURL { phone.runnerURL = url }
    }

    /// What the QR code said: the gateway's URL, the Mac's link and the one-time secret.
    private func pair(_ value: String) async {
        do {
            try await phone.pair(scanned: value)
            problem = nil
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
            typing = false
            problem = nil
        } catch { problem = error.localizedDescription }
    }
}

/// Six boxes for the Mac's code (docs/ios-design.md "Connect"): one field underneath, the digits
/// shown in 44pt boxes, the next one edged in `fieldEdgeOn` while typing.
private struct DigitBoxes: View {
    @Binding var code: String
    var typing: FocusState<Bool>.Binding

    var body: some View {
        let digits = Array(code.filter(\.isNumber).prefix(6))
        ZStack {
            // The field VoiceOver reaches, over the boxes; they only draw what's typed.
            TextField("Six-digit code", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .focused(typing)
                .opacity(0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Six-digit code")
                .accessibilityHint("The code Oby on your Mac shows")
                .onChange(of: code) { _, typed in
                    let kept = String(typed.filter(\.isNumber).prefix(6))
                    if kept != typed { code = kept }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    Text(index < digits.count ? String(digits[index]) : "")
                        .font(Tokens.mono(22)).foregroundStyle(Tokens.ink)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Tokens.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(typing.wrappedValue && index == min(digits.count, 5) ? Tokens.fieldEdgeOn : Tokens.line)
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { typing.wrappedValue = true }
    }
}

/// The screen's one `ink` button, full width.
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size = Tokens.textLg

    var body: some View {
        Button(action: action) {
            Text(title).font(Tokens.font(size, .medium)).foregroundStyle(Tokens.onInk)
                .frame(maxWidth: .infinity).padding(.vertical, 12).frame(minHeight: 48)
                .background(Tokens.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension Phone {
    /// Pairs with what the Mac's QR code (or an invitation pasted) says: through the Mac's
    /// Obysphere when it came through one, and then only so.
    func pair(scanned value: String) async throws {
        let envelope = try GatewayEnvelope.decode(value)
        if let relay = envelope.relay {
            try await pairRelay(relay, credential: envelope.secret, mac: envelope.link)
        } else {
            try await pairGateway(url: envelope.url, credential: envelope.secret, link: envelope.link)
        }
    }
}

/// What the Mac's pairing QR code carries (apps/mac/app/PairingView.swift): the gateway's URL, the Mac's
/// link (its name and tunnel hostname) and the one-time secret. Made while obid is in an Obysphere,
/// the link has `relay` too (docs/runner-api.md, "obid only: the phone relay"): the Sphere, the
/// relay, this phone's relay token and the Mac's key.
struct GatewayEnvelope: Decodable, Equatable {
    var url: URL
    var link: MacLink
    var secret: String
    var relay: RelayLink?

    private enum Keys: String, CodingKey { case url, link, secret }
    private struct Relayed: Decodable { var relay: RelayLink? }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        url = try keys.decode(URL.self, forKey: .url)
        link = try keys.decode(MacLink.self, forKey: .link)
        relay = try keys.decode(Relayed.self, forKey: .link).relay
        secret = try keys.decode(String.self, forKey: .secret)
    }

    static func decode(_ text: String) throws -> GatewayEnvelope {
        let envelope: GatewayEnvelope
        do {
            envelope = try JSONDecoder().decode(GatewayEnvelope.self, from: Data(text.utf8))
        } catch {
            throw RunnerError(message: "That isn't Oby's pairing QR code. Scan the one the Mac's Settings › Runner shows.")
        }
        // Through an Obysphere the hostname is only the Mac's name: the relay is the way, and its
        // key the Mac's, sealed to from the first call. A pasted one still names its Mac plainly:
        // a hostname of letters, digits, dots and dashes with a port at most (a Tailscale route's
        // `mac.tail0000.ts.net:8443`), a name of one line, both short. Who the Mac is is its relay
        // and key (MacLink.identity), never these.
        if let relay = envelope.relay {
            let host = envelope.link.hostname.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = envelope.link.name
            guard relay.isValid, (1...253).contains(host[0].count),
                  host[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                  host.count == 1 || (1...5).contains(host[1].count) && host[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  (1...64).contains(name.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RunnerError(message: "That invitation's Obysphere isn't one Oby can reach safely, so Oby won't pair with it.")
            }
            return envelope
        }
        // An invitation pasted from a message could send this iPhone anywhere: it must point at
        // the Mac it names, over HTTPS, or at a gateway on the home network.
        guard MacLink.isHostname(envelope.link.hostname), envelope.reachesItsMac else {
            throw RunnerError(message: "That invitation doesn't point at the Mac it names, so Oby won't pair with it.")
        }
        return envelope
    }

    /// The URL is the link's own hostname over HTTPS, or plain HTTP to a home-network address.
    private var reachesItsMac: Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if url.scheme == "https" {
            return (url.port.map { "\(host):\($0)" } ?? host) == link.hostname.lowercased()
        }
        guard url.scheme == "http" else { return false }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
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

struct QRScanner: UIViewControllerRepresentable {
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
