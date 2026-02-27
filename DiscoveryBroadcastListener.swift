import Foundation
import Network

final class DiscoveryBroadcastListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "discovery.broadcast.listener.queue")
    private let discoveryPort: UInt16 = 5961
    
    typealias BroadcastHandler = (String) -> Void
    
    func startListening(completion: @escaping BroadcastHandler) {
        queue.async {
            do {
                let parameters = NWParameters.udp
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.discoveryPort)!)
                
                listener.newConnectionHandler = { _ in }
                
                listener.receiveMessage { (content, context, isComplete, error) in
                    if let error = error {
                        print("[DiscoveryBroadcast] Error: \(error)")
                        return
                    }
                    
                    guard let content = content else { return }
                    
                    if let message = String(data: content, encoding: .utf8) {
                        print("[DiscoveryBroadcast] Received broadcast: \(message)")
                        
                        if let ip = self.parseServerBroadcast(message) {
                            print("[DiscoveryBroadcast] Server found: \(ip)")
                            DispatchQueue.main.async {
                                completion(ip)
                            }
                        }
                    }
                    
                    listener.receiveMessage(completion: { content, context, isComplete, error in })
                }
                
                listener.stateUpdateHandler = { state in
                    print("[DiscoveryBroadcast] Listener state: \(state)")
                }
                
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                print("[DiscoveryBroadcast] Failed to start listener: \(error)")
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    private func parseServerBroadcast(_ message: String) -> String? {
        // Erwartet Format: "IRIUM_CLONE_SERVER:192.168.1.100"
        let parts = message.split(separator: ":")
        if parts.count == 2 && parts[0] == "IRIUM_CLONE_SERVER" {
            return String(parts[1])
        }
        return nil
    }
}
