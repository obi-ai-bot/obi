import Foundation

/// Advertises the gateway on the local network. Linux keeps this as a no-op because the runner's
/// package tests have no Bonjour stack; the Mac runner uses Foundation's system service publisher.
@MainActor
final class Bonjour {
    #if canImport(Darwin)
    private var service: NetService?
    #endif

    func start(port: Int, name: String = Host.current().localizedName ?? "Oby") {
        #if canImport(Darwin)
        let service = NetService(domain: "local.", type: "_oby._tcp.", name: name, port: Int32(port))
        service.includesPeerToPeer = true
        service.publish(options: .listenForConnections)
        self.service = service
        #else
        _ = (port, name)
        #endif
    }

    func stop() {
        #if canImport(Darwin)
        service?.stop()
        service = nil
        #endif
    }
}
