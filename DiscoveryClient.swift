import Foundation
import Network

final class DiscoveryClient {
    private let queue = DispatchQueue(label: "discovery.client.queue")
    private var udpConnection: NWConnection?
    
    var onServerFound: ((String) -> Void)?
    
    func startSearching() {
        // Starte UDP-Listener auf Discovery-Port (5961)
        let params = NWParameters.udp
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.broadcast), port: 5961)
        
        udpConnection = NWConnection(to: endpoint, using: params)
        udpConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveDiscoveryMessages()
            case .failed(let error):
                print("[Discovery] Connection failed: \(error)")
            default:
                break
            }
        }
        
        udpConnection?.start(queue: queue)
        
        // Sende auch eine Discovery-Anfrage
        sendDiscoveryRequest()
    }
    
    private func sendDiscoveryRequest() {
        guard let connection = udpConnection else { return }
        
        let message = "IRIUM_CLONE_CLIENT:\(UIDevice.current.name)"
        if let data = message.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }
    
    private func receiveDiscoveryMessages() {
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8) {
                    print("[Discovery] Received: \(message)")
                    
                    // Parse "IRIUM_CLONE_SERVER:192.168.x.x"
                    if message.hasPrefix("IRIUM_CLONE_SERVER:") {
                        let parts = message.split(separator: ":")
                        if parts.count == 2 {
                            let serverIP = String(parts[1])
                            DispatchQueue.main.async {
                                self?.onServerFound?(serverIP)
                            }
                        }
                    }
                }
            }
            
            if error == nil {
                self?.receiveDiscoveryMessages()
            }
        }
    }
    
    func stop() {
        udpConnection?.cancel()
        udpConnection = nil
    }
}
