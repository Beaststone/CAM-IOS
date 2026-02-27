import Foundation
import Network
import Combine

final class DiscoveryClient: NSObject, NSNetServiceBrowserDelegate, NSNetServiceDelegate {
    let discoveredPublisher = PassthroughSubject<(name: String, ipAddress: String), Never>()
    private let queue = DispatchQueue(label: "discovery.client.queue")
    private var udpSocket: CFSocket?
    
    func startDiscovery() {
        print("[DiscoveryClient] Starting discovery on port 5961...")
        
        // UDP Socket erstellen zum Abhören von Discovery Broadcasts
        queue.async { [weak self] in
            self?.listenForBroadcasts()
        }
    }
    
    private func listenForBroadcasts() {
        do {
            let socket = try Socket(protocolFamily: AF_INET)
            let port = UInt16(5961)
            
            // Socket binden
            var socketAddress = sockaddr_in()
            socketAddress.sin_family = __uint8_t(AF_INET)
            socketAddress.sin_addr.s_addr = htonl(UInt32(INADDR_ANY))
            socketAddress.sin_port = port.bigEndian
            
            let addressData = NSData(bytes: &socketAddress, length: MemoryLayout<sockaddr_in>.size)
            
            // Einfachere Lösung: NWListener verwenden
            listenWithNWListener()
        } catch {
            print("[DiscoveryClient] Failed to create socket: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.listenForBroadcasts()
            }
        }
    }
    
    private func listenWithNWListener() {
        do {
            let parameters = NWParameters.udp
            let listener = try NWListener(using: parameters, on: 5961)
            
            listener.newConnectionHandler = { connection in
                // Nicht relevant für UDP Discovery
            }
            
            listener.stateUpdateHandler = { state in
                print("[DiscoveryClient] Listener state: \(state)")
            }
            
            listener.start(queue: queue)
            
            // Jetzt empfangen wir auf diesem Port
            receiveDiscoveryBroadcasts(listener: listener)
        } catch {
            print("[DiscoveryClient] Failed to create listener: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.listenWithNWListener()
            }
        }
    }
    
    private func receiveDiscoveryBroadcasts(listener: NWListener) {
        // Für UDP Broadcasts verwenden wir einen direkteren Ansatz
        DispatchQueue.global().async { [weak self] in
            self?.receiveOnUDPPort5961()
        }
    }
    
    private func receiveOnUDPPort5961() {
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else {
            print("[DiscoveryClient] Failed to create UDP socket")
            return
        }
        
        defer { close(socket) }
        
        // Socket auf Broadcast vorbereiten
        var broadcastEnable: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind an Port 5961
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr.s_addr = INADDR_ANY
        socketAddress.sin_port = UInt16(5961).bigEndian
        socketAddress.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        
        let bindResult = withUnsafePointer(to: &socketAddress) { ptr in
            bind(socket, UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        
        guard bindResult >= 0 else {
            print("[DiscoveryClient] Failed to bind socket: \(errno)")
            return
        }
        
        print("[DiscoveryClient] Listening on UDP port 5961...")
        
        // Empfangen
        var buffer = [UInt8](repeating: 0, count: 1024)
        var remoteAddress = sockaddr_in()
        var remoteAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        while true {
            let bytesRead = withUnsafeMutablePointer(to: &remoteAddress) { remotePtr in
                recvfrom(socket,
                        &buffer,
                        buffer.count,
                        0,
                        UnsafeMutableRawPointer(remotePtr).assumingMemoryBound(to: sockaddr.self),
                        &remoteAddressLength)
            }
            
            guard bytesRead > 0 else {
                continue
            }
            
            let data = Data(bytes: buffer, count: bytesRead)
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
    }
    
    func stop() {
        print("[DiscoveryClient] Stopped")
    }
}

// Helper Klasse für Socket-Verwaltung
class Socket {
    let fileDescriptor: Int32
    
    init(protocolFamily: Int32) throws {
        fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "Socket", code: -1)
        }
    }
    
    deinit {
        close(fileDescriptor)
    }
}
