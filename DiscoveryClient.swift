import Foundation
import Network
import Combine

final class DiscoveryClient {
    let discoveredPublisher = PassthroughSubject<(name: String, ipAddress: String), Never>()
    private let queue = DispatchQueue(label: "discovery.client.queue")
    private var listener: NWListener?

    func startDiscovery() {
        print("[DiscoveryClient] Starting discovery on port 5961...")
        queue.async { [weak self] in
            self?.setupUDPListener()
        }
    }

    private func setupUDPListener() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: 5961)

            guard let listener = listener else { return }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.stateUpdateHandler = { state in
                print("[DiscoveryClient] Listener state: \(state)")
            }

            listener.start(queue: queue)
            print("[DiscoveryClient] UDP listener started on port 5961")
        } catch {
            print("[DiscoveryClient] Failed to create listener: \(error)")
            // Retry nach kurzer Zeit
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.setupUDPListener()
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            print("[DiscoveryClient] Connection state: \(state)")
        }

        receiveData(on: connection)
        connection.start(queue: queue)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8) {
                    print("[DiscoveryClient] Received: \(message)")

                    // Parse der Discovery-Nachricht: "IRIUM_CLONE_SERVER:192.168.2.1"
                    if message.starts(with: "IRIUM_CLONE_SERVER:") {
                        let ipPart = String(message.dropFirst("IRIUM_CLONE_SERVER:".count))
                        print("[DiscoveryClient] Found PC at \(ipPart)")

                        DispatchQueue.main.async { [weak self] in
                            self?.discoveredPublisher.send((name: "Windows PC", ipAddress: ipPart))
                        }
                    }
                }
            }

            if error == nil && !isComplete {
                self?.receiveData(on: connection)
            }
        }
    }

    func stop() {
        print("[DiscoveryClient] Stopped")
        listener?.cancel()
        listener = nil
    }
}
