import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Runner's device pairing (#284). The invitation is made on the runner's loopback API
/// with the runner's own token (`POST /v1/pairing/invite`), which only this app holds: a phone
/// reaching the gateway can redeem an invitation but can't mint one, and nothing on this Mac can
/// read a file for it. The QR contains the gateway URL, the link JSON, and the one-time secret.
/// The URL is a route a phone can reach the gateway by (`PairingRoute`): Remote access's hostname,
/// or the gateway as `tailscale serve` publishes it on the tailnet.
struct PairingView: View {
    let feed: RunnerFeed
    let remote: RemoteAccess?
    @Environment(\.openSettingsPage) private var openSettings
    @State private var invitation: GatewayInvitation?
    /// The route the invitation was made for, shown with its QR.
    @State private var invited: PairingRoute?
    /// What the tailnet offers, and the gateway's port (nil: obid has no gateway); nil until looked for once.
    @State private var tailnet: (PairingRoute.Tailnet, port: Int?)?
    @State private var chosen: PairingRoute?
    @State private var devices: [PairedGatewayDevice] = []
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        SetGroup("Pair a device", problem: problem) {
            if let invitation, let invited {
                SetRow(about: "\(invited.label). Valid for two minutes. The code is single-use.") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let image = Self.qr(invitation.qrText) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                                .accessibilityLabel("Pairing QR code")
                        }
                        Text("Fallback code: \(invitation.code)").font(Tokens.font(Tokens.textLg).monospacedDigit()).textSelection(.enabled)
                    }
                }
            }
            if let (title, about) = blocker {
                // The buttons check again once it's fixed.
                SetRow(title, about: about) {
                    if remote != nil, routes.isEmpty {
                        Button("Allow Remote Access") { openSettings(.remote, spotlight: .remoteAccess) }
                            .buttonStyle(.set)
                    }
                    Button("Check again") { Task { await findTailscale() } }
                        .buttonStyle(.set)
                }
            }
            if tailnet == nil || !routes.isEmpty {
                if routes.count > 1 {
                    SetRow("Pair over") {
                        SetSelect("Pair over", selection: Binding { route } set: { chosen = $0 },
                                  options: routes.map { (Optional($0), $0.label) })
                    }
                }
                SetRow(routes.count == 1 ? route?.label ?? "" : "") {
                    Button(busy ? "Creating…" : invitation == nil ? "Pair a device" : "Create new invitation") {
                        openSettings.clear(.pairDevice)
                        Task { await create() }
                    }
                    .buttonStyle(.set)
                    .disabled(busy || route == nil)
                }
                .spotlit(openSettings.spotlight == .pairDevice, id: .pairDevice)
            }
        }
        .onDisappear { openSettings.clear(.pairDevice) }
        SetGroup("Paired devices", footer: "Revoke a lost phone here. It will need to pair again before it can reach this Mac.") {
            if devices.isEmpty {
                SetRow("None yet", quiet: true)
            }
            ForEach(devices) { device in
                SetRow(device.name, about: "Expires \(device.expiresAt.formatted(date: .abbreviated, time: .shortened))") {
                    Button("Revoke", role: .destructive) {
                        Task { await revoke(device) }
                    }
                    .buttonStyle(.set)
                }
            }
        }
        .task { await loadDevices() }
        .task { await findTailscale() }
        // Back from Terminal, where `tailscale serve` may have just been run.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await findTailscale() }
        }
    }

    private var remoteHostname: String? {
        guard remote?.on == true, let hostname = remote?.hostname, MacLink.isHostname(hostname) else { return nil }
        return hostname
    }

    private var routes: [PairingRoute] {
        // With no gateway, neither route reaches anything.
        if let tailnet, tailnet.port == nil { return [] }
        guard case .route(let host) = tailnet?.0 else { return PairingRoute.routes(remote: remoteHostname, tailscale: nil) }
        return PairingRoute.routes(remote: remoteHostname, tailscale: host)
    }

    /// Why the tailnet, or every route, is out, once looked for.
    private var blocker: (String, String)? {
        guard let (found, port) = tailnet else { return nil }
        guard let port else {
            return ("The gateway is off", "obid's configuration has no gateway, so no phone can reach this Mac. Add \"gateway\": \"127.0.0.1:8810\" to \(PairingRoute.configFile.path), then turn Settings › Runner › This Mac off and on again.")
        }
        if found == .funnel {
            return ("The gateway is public through Tailscale Funnel", "Turn Funnel off for it first: Oby never pairs a phone over the internet.")
        }
        guard routes.isEmpty else { return nil }
        return ("No way to reach this Mac yet", "Turn on Remote access, or publish the gateway on your tailnet: \(PairingRoute.serveCommand(port: port))")
    }

    /// The one the user picked while it's still there, else the first.
    private var route: PairingRoute? { chosen.flatMap { routes.contains($0) ? $0 : nil } ?? routes.first }

    private func findTailscale() async {
        if let port = PairingRoute.gatewayPort() {
            tailnet = (await PairingRoute.tailnet(port: port), port)
        } else {
            tailnet = (.nothing, nil)
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let name = Host.current().localizedName ?? "Mac"
            guard let route else {
                throw RunnerError(message: "Turn on Remote access, or publish the gateway on your tailnet, before creating a pairing QR code.")
            }
            var request = try runnerRequest(path: "v1/pairing/invite", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Invite(name: name, hostname: route.hostname, url: "https://\(route.hostname)"))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RunnerError(message: "The runner refused to create a pairing invitation.") }
            invitation = try PairingPayloadDecoder.decodeInvitation(data)
            invited = route
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// A request to the runner on this Mac, with its keychain token (Engine/LocalRunner.swift):
    /// pairing lives on the loopback API, which answers only that token.
    private func runnerRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard feed.local, let runner = feed.runner else {
            throw RunnerError(message: "Pairing needs the runner on this Mac: turn on Settings › Runner › This Mac first.")
        }
        var request = URLRequest(url: runner.base.appending(path: path))
        request.httpMethod = method
        if let token = runner.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func loadDevices() async {
        do {
            let request = try runnerRequest(path: "v1/pairing/devices")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            devices = try PairingPayloadDecoder.decodeDevices(data)
        } catch {
            // The runner may be off while Settings is open; pairing can still be created later.
        }
    }

    private func revoke(_ device: PairedGatewayDevice) async {
        do {
            let request = try runnerRequest(path: "v1/pairing/devices/\(device.id)", method: "DELETE")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
                throw RunnerError(message: "The runner refused to revoke that device.")
            }
            devices.removeAll { $0.id == device.id }
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private static func qr(_ text: String) -> NSImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        guard let output = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let rep = NSCIImageRep(ciImage: output.transformed(by: scale))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private struct Invite: Encodable { var name: String; var hostname: String; var url: String }
}

/// A way a phone reaches this Mac's gateway over HTTPS, as an invitation advertises it: its
/// `hostname` is the link's, port included for Tailscale (docs/runner-api.md, "obid only: the
/// gateway"). Never a Funnel URL: the gateway stays off the public internet.
nonisolated enum PairingRoute: Hashable, Sendable {
    /// Remote access's hostname (RemoteAccess).
    case remote(String)
    /// `host.tailnet.ts.net:port`, from `tailscale serve`.
    case tailscale(String)

    var hostname: String {
        switch self { case .remote(let host), .tailscale(let host): host }
    }

    var label: String {
        switch self {
        case .remote(let host): "Through Remote access: \(host)"
        case .tailscale(let host): "Over Tailscale: \(host)"
        }
    }

    /// Remote access first when it's on, then the tailnet.
    static func routes(remote: String?, tailscale: String?) -> [PairingRoute] {
        [remote.map(PairingRoute.remote), tailscale.map(PairingRoute.tailscale)].compactMap { $0 }
    }

    static func serveCommand(port: Int) -> String { "tailscale serve --bg --https=8443 http://127.0.0.1:\(port)" }

    static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Oby/obid/config.json")

    /// The gateway's port in obid's configuration (`"gateway": "127.0.0.1:8810"`): 8810 with no
    /// configuration yet (obid writes that one), nil when it has no gateway or a port that isn't one.
    static func gatewayPort(config: Data? = try? Data(contentsOf: configFile)) -> Int? {
        guard let config else { return 8810 }
        guard let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let gateway = object["gateway"] as? String,
              let port = gateway.split(separator: ":").last.flatMap({ Int($0) }), (1...65535).contains(port)
        else { return nil }
        return port
    }

    static let tailscaleCLIs = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                                "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    /// What the tailnet offers for pairing.
    nonisolated enum Tailnet: Equatable, Sendable {
        /// `host:port`, tailnet only.
        case route(String)
        /// The gateway is public through Funnel, somewhere: no route until that's off.
        case funnel
        /// No Tailscale, or nothing on it proxies to the gateway.
        case nothing
    }

    /// The tailnet route to the gateway on `port`, from the first Tailscale CLI there is. Only
    /// `status` runs: Oby never changes Tailscale's configuration. The app's own binary acts as the
    /// CLI only with `TAILSCALE_BE_CLI` when no shell started it.
    static func tailnet(port: Int, clis: [String] = tailscaleCLIs) async -> Tailnet {
        guard let cli = clis.first(where: FileManager.default.isExecutableFile(atPath:)),
              let output = try? await LimitedCommand.run([cli, "serve", "status", "--json"], outputLimit: 1 << 20, timeout: 5,
                                                         environment: ["PATH": "/usr/bin:/bin", "TAILSCALE_BE_CLI": "1"]),
              output.status == 0 else { return .nothing }
        return tailnet(serveStatus: output.out, port: port)
    }

    /// The `host:port` in `tailscale serve status --json` whose root proxies to the gateway on
    /// 127.0.0.1:`port` (an HTTPS handler, or a TCP forward that ends TLS), tailnet only. When any
    /// Funnel `host:port` (in the background config or a foreground session's) reaches the gateway,
    /// on any path, there's no route: pairing would advertise a gateway that's on the internet.
    static func tailnet(serveStatus: Data, port: Int) -> Tailnet {
        guard let status = try? JSONDecoder().decode(ServeStatus.self, from: serveStatus) else { return .nothing }
        let gateway = { (target: String?) in
            guard var target else { return false }
            if let scheme = target.firstRange(of: "://") {
                guard target.hasPrefix("http://") || target.hasPrefix("tcp://") else { return false }
                target = String(target[scheme.upperBound...])
            }
            return target == "127.0.0.1:\(port)" || target == "localhost:\(port)"
        }
        let configs = [status] + (status.Foreground ?? [:]).values
        let funnel = Set(configs.flatMap { ($0.AllowFunnel ?? [:]).filter(\.value).keys })
        let exposed = configs.contains { config in
            funnel.contains { hostPort in
                let tcpPort = hostPort.split(separator: ":").last.map(String.init) ?? ""
                return config.Web?[hostPort]?.Handlers?.values.contains { gateway($0.Proxy) } == true
                    || gateway(config.TCP?[tcpPort]?.TCPForward)
            }
        }
        if exposed { return .funnel }
        let web = (status.Web ?? [:]).filter { gateway($0.value.Handlers?["/"]?.Proxy) }.keys
        let tcp = (status.TCP ?? [:]).compactMap { tcpPort, handler in
            gateway(handler.TCPForward) ? handler.TerminateTLS.map { "\($0):\(tcpPort)" } : nil
        }
        return (Array(web) + tcp).filter(MacLink.isHostname).sorted().first.map(Tailnet.route) ?? .nothing
    }

    /// The parts of Tailscale's ServeConfig that say where a port goes.
    private struct ServeStatus: Decodable {
        struct TCPHandler: Decodable { var TCPForward: String?; var TerminateTLS: String? }
        struct Handler: Decodable { var Proxy: String? }
        struct Web: Decodable { var Handlers: [String: Handler]? }
        var TCP: [String: TCPHandler]?
        var Web: [String: Web]?
        var AllowFunnel: [String: Bool]?
        /// `tailscale serve` or `funnel` run without `--bg`, by session.
        var Foreground: [String: ServeStatus]?
    }
}

struct GatewayInvitation: Decodable {
    var url: String
    var name: String
    var hostname: String
    var link: String
    var secret: String
    var code: String
    var expiresAt: Date
    var qrText: String { "{\"url\":\"\(url)\",\"link\":\(link),\"secret\":\"\(secret)\"}" }
}

struct PairedGatewayDevice: Decodable, Identifiable {
    var id: String
    var name: String
    var created: Date
    var expiresAt: Date
}

enum PairingPayloadDecoder {
    static func decodeInvitation(_ data: Data) throws -> GatewayInvitation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GatewayInvitation.self, from: data)
    }

    static func decodeDevices(_ data: Data) throws -> [PairedGatewayDevice] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PairedGatewayDevice].self, from: data)
    }
}
