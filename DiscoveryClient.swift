import Foundation
import Network

final class DiscoveryClient {
    private let queue = DispatchQueue(label: "discovery.client.queue")
    private let discoveryPort: UInt16 = 5961
    
    typealias DiscoveryHandler = (String) -> Void
    
    func findServer(timeout: TimeInterval = 10.0, completion: @escaping DiscoveryHandler) {
        queue.async {
            self.performDiscovery(timeout: timeout, completion: completion)
        }
    }
    
    private func performDiscovery(timeout: TimeInterval, completion: @escaping DiscoveryHandler) {
        let endpoint = NWEndpoint.hostPort(host: .any, port: NWEndpoint.Port(rawValue: discoveryPort)!)
        var params = NWParameters.udp
        params.allowFastOpen = true
        
        let connection = NWConnection(to: endpoint, using: params)
        var foundServer = false
        
        let timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            if !foundServer {
                print("[DiscoveryClient] Discovery timeout - using fallback")
                connection.cancel()
                DispatchQueue.main.async {
                    completion("192.168.2.229")
                }
            }
        }
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[DiscoveryClient] Discovery connection ready, sending request...")
                self.sendDiscoveryRequest(connection, completion: { ip in
                    foundServer = true
                    timeoutTimer.invalidate()
                    connection.cancel()
                    completion(ip)
                })
            case .failed(let error):
                print("[DiscoveryClient] Discovery failed: \(error)")
                if !foundServer {
                    timeoutTimer.invalidate()
                    connection.cancel()
                    DispatchQueue.main.async {
                        completion("192.168.2.229")
                    }
                }
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func sendDiscoveryRequest(_ connection: NWConnection, completion: @escaping (String) -> Void) {
        let message = "IRIUM_CLONE_CLIENT"
        guard let data = message.data(using: .utf8) else { return }
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[DiscoveryClient] Error sending request: \(error)")
                return
            }
            
            print("[DiscoveryClient] Discovery request sent, waiting for response...")
            self.receiveDiscoveryResponse(connection, completion: completion)
        })
    }
    
    private func receiveDiscoveryResponse(_ connection: NWConnection, completion: @escaping (String) -> Void) {
        connection.receiveMessage { data, context, isComplete, error in
            if let error = error {
                print("[DiscoveryClient] Error receiving response: \(error)")
                return
            }
            
            guard let data = data else { return }
            
            if let message = String(data: data, encoding: .utf8) {
                print("[DiscoveryClient] Received: \(message)")
                
                if let ip = self.parseServerResponse(message) {
                    print("[DiscoveryClient] Discovered server IP: \(ip)")
                    DispatchQueue.main.async {
                        completion(ip)
                    }
                    return
                }
            }
            
            // Weiter auf Antwort warten
            self.receiveDiscoveryResponse(connection, completion: completion)
        }
    }
    
    private func parseServerResponse(_ message: String) -> String? {
        // Erwartet Format: "IRIUM_CLONE_SERVER:192.168.1.100"
        let parts = message.split(separator: ":")
        if parts.count == 2 && parts[0] == "IRIUM_CLONE_SERVER" {
            return String(parts[1])
        }
        return nil
    }
}
