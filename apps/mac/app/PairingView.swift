import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Runner's device pairing (#284). The invitation is made on the runner's loopback API
/// with the runner's own token (`POST /v1/pairing/invite`), which only this app holds: a phone
/// reaching the gateway can redeem an invitation but can't mint one, and nothing on this Mac can
/// read a file for it. The QR contains the gateway URL, the link JSON, and the one-time secret.
struct PairingView: View {
    let feed: RunnerFeed
    let remote: RemoteAccess?
    @Environment(\.openSettingsPage) private var openSettings
    @State private var invitation: GatewayInvitation?
    @State private var devices: [PairedGatewayDevice] = []
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        SetGroup("Pair a device", problem: problem) {
            if let invitation {
                SetRow(about: "Valid for two minutes. The code is single-use. LAN pairing uses HTTP plus a device token.") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let image = Self.qr(invitation.qrText) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                                .accessibilityLabel("Pairing QR code")
                        }
                        Text("Fallback code: \(invitation.code)").font(Tokens.font(Tokens.textLg).monospacedDigit()).textSelection(.enabled)
                    }
                }
            }
            if remote != nil, !remoteOn {
                // A phone pairs through Remote access: the button goes there, and comes back once it's on.
                SetRow("Remote access is off", about: "Your iPhone reaches this Mac through Remote access. Allow it, then pair.") {
                    Button("Allow Remote Access") { openSettings(.remote, spotlight: .remoteAccess) }
                        .buttonStyle(.set)
                }
            } else {
                SetRow("") {
                    Button(busy ? "Creating…" : invitation == nil ? "Pair a device" : "Create new invitation") {
                        openSettings.clear(.pairDevice)
                        Task { await create() }
                    }
                    .buttonStyle(.set)
                    .disabled(busy)
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
    }

    private var remoteOn: Bool { remote?.step == .on && remote?.hostname.map(MacLink.isHostname) == true }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let name = Host.current().localizedName ?? "Mac"
            guard let hostname = remote?.hostname, MacLink.isHostname(hostname),
                  let advertisedURL = URL(string: "https://\(hostname)") else {
                throw RunnerError(message: "Turn on Remote access before creating a pairing QR code.")
            }
            var request = try runnerRequest(path: "v1/pairing/invite", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Invite(name: name, hostname: hostname, url: advertisedURL.absoluteString))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RunnerError(message: "The runner refused to create a pairing invitation.") }
            invitation = try PairingPayloadDecoder.decodeInvitation(data)
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
