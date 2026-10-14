import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Runner's device pairing (#284). The invitation is made on the runner's owner Unix
/// socket with the runner's own token (`POST /v1/pairing/invite`), which only this app holds: a
/// phone reaching the gateway can redeem an invitation but can't mint one, and nothing on this Mac
/// can read a file for it. The QR contains the gateway URL, the link JSON, and the one-time secret.
struct PairingView: View {
    let feed: RunnerFeed
    let remote: RemoteAccess?
    @State private var invitation: GatewayInvitation?
    @State private var devices: [PairedGatewayDevice] = []
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        Section("Pair a device") {
            if let invitation {
                if let image = Self.qr(invitation.qrText) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .accessibilityLabel("Pairing QR code")
                }
                Text("Fallback code: \(invitation.code)").font(.title3.monospacedDigit())
                Text("Valid for two minutes. The code is single-use.").font(.caption).foregroundStyle(.secondary)
                Text("LAN pairing uses HTTP plus a device token.").font(.caption).foregroundStyle(.secondary)
            }
            Button(busy ? "Creating…" : invitation == nil ? "Pair a device" : "Create new invitation") {
                Task { await create() }
            }.disabled(busy)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        Section {
            if devices.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text("Expires \(device.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task { await revoke(device) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Paired devices")
        } footer: {
            Text("Revoke a lost phone here. It will need to pair again before it can reach this Mac.")
        }
        .task { await loadDevices() }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let name = Host.current().localizedName ?? "Mac"
            guard let hostname = remote?.hostname, MacLink.isHostname(hostname),
                  let advertisedURL = URL(string: "https://\(hostname)") else {
                throw RunnerError(message: "Turn on Remote access before creating a pairing QR code.")
            }
            let runner = try localRunner()
            let data = try await runner.createPairingInvitation(name: name, hostname: hostname,
                                                                url: advertisedURL.absoluteString)
            invitation = try PairingPayloadDecoder.decodeInvitation(data)
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// The runner on this Mac, over its owner Unix socket with the keychain token (#397).
    private func localRunner() throws -> Runner {
        guard feed.local, let runner = feed.runner, runner.unixSocket != nil else {
            throw RunnerError(message: "Pairing needs the runner on this Mac: turn on Settings › Runner › This Mac first.")
        }
        return runner
    }

    private func loadDevices() async {
        do {
            let data = try await localRunner().pairedGatewayDevices()
            devices = try PairingPayloadDecoder.decodeDevices(data)
        } catch {
            // The runner may be off while Settings is open; pairing can still be created later.
        }
    }

    private func revoke(_ device: PairedGatewayDevice) async {
        do {
            try await localRunner().revokeGatewayDevice(device.id)
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
