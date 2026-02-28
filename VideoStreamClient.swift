import Foundation
import Network

final class VideoStreamClient {
    private var udpConnection: NWConnection?
    private var tcpListener: NWListener?
    private var tcpClientConnection: NWConnection?
    
    private let queue = DispatchQueue(label: "video.stream.client.queue")

    private var isUSBMode = false
    private var currentPort: UInt16?

    func connect(to host: String, port: UInt16, isUSB: Bool) {
        if self.isUSBMode == isUSB && self.currentPort == port && (tcpListener != nil || udpConnection != nil) {
            print("[VideoStreamClient] Already connected/listening on \(port). Skipping restart.")
            return
        }

        self.isUSBMode = isUSB
        self.currentPort = port
        stop()

        if isUSB {
            startTCPServer(port: port)
        } else {
            startUDPClient(host: host, port: port)
        }
    }

    private func startUDPClient(host: String, port: UInt16) {
        print("[VideoStreamClient-UDP] Connecting to \(host):\(port)...")
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp
        
        udpConnection = NWConnection(host: nwHost, port: nwPort, using: params)
        udpConnection?.stateUpdateHandler = { state in
            print("[VideoStreamClient-UDP] State: \(state)")
        }
        udpConnection?.start(queue: queue)
    }

    private func startTCPServer(port: UInt16) {
        if tcpListener != nil { return }
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // params.requiredInterfaceType = .loopback // Entfernt für maximale Kompatibilität falls usbmuxd anders routet
            
            tcpListener = try NWListener(using: params, on: nwPort)
            
            tcpListener?.stateUpdateHandler = { state in
                print("[VideoStreamClient-TCPServer] Listener State: \(state)")
            }
            
            tcpListener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewTCPConnection(newConnection)
            }
            
            tcpListener?.start(queue: queue)
            print("[VideoStreamClient-TCPServer] Listening on port \(port)...")
        } catch {
            print("[VideoStreamClient-TCPServer] Error: \(error)")
        }
    }

    private func handleNewTCPConnection(_ connection: NWConnection) {
        // Schließe alte Verbindung falls PC neu verbindet
        tcpClientConnection?.cancel()
        
        connection.stateUpdateHandler = { state in
            print("[VideoStreamClient-TCPServer] Client State: \(state)")
        }
        
        // Empfangen von (Dummy)-Daten starten, damit die Connection open bleibt
        receiveTCP(on: connection)
        
        connection.start(queue: queue)
        tcpClientConnection = connection
    }

    private func receiveTCP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, context, isComplete, error in
            if let error = error {
                print("[VideoStreamClient-TCPServer] Receive error: \(error)")
                self?.tcpClientConnection = nil
                return
            }
            if isComplete {
                print("[VideoStreamClient-TCPServer] Connection closed by PC")
                self?.tcpClientConnection = nil
                return
            }
            // Weiter auf Daten hören falls PC was sendet (wir schicken primär)
            self?.receiveTCP(on: connection)
        }
    }

    private var pendingSends = 0
    private let maxPendingSends = 10 // Max 10 Frames in der Queue bevor wir droppen

    /// Sendet einen Annex-B H.264-Frame.
    /// UDP für WLAN, TCP für natives USB-Kabel.
    func send(frameData: Data) {
        // Backpressure Check: Wenn Netzwerk zu langsam, Frames verwerfen (Low Latency)
        guard pendingSends < maxPendingSends else {
            return
        }

        if self.isUSBMode {
            guard let conn = tcpClientConnection else { return }
            
            // Framing: 4-Byte Length Header (Little Endian)
            var length = UInt32(frameData.count).littleEndian
            
            // Wir bauen das Paket effizient zusammen
            var payload = Data(capacity: 4 + frameData.count)
            withUnsafeBytes(of: length) { payload.append(contentsOf: $0) }
            payload.append(frameData)
            
            pendingSends += 1
            conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                self?.queue.async {
                    self?.pendingSends -= 1
                    if let error = error {
                        print("[VideoStreamClient-TCP] Send error: \(error)")
                    }
                }
            })
        } else {
            // WLAN UDP
            guard let conn = udpConnection else { return }
            pendingSends += 1
            conn.send(content: frameData, completion: .contentProcessed { [weak self] error in
                self?.queue.async {
                    self?.pendingSends -= 1
                }
            })
        }
    }

    func stop() {
        udpConnection?.cancel()
        udpConnection = nil
        
        tcpClientConnection?.cancel()
        tcpClientConnection = nil
        
        tcpListener?.cancel()
        tcpListener = nil
    }
}

