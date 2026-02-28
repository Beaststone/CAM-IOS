import Foundation
import Network

final class VideoStreamClient {
    private var udpConnection: NWConnection?
    private var tcpListener: NWListener?
    private var tcpClientConnection: NWConnection?
    
    private let queue = DispatchQueue(label: "video.stream.client.queue")

    private var isUSBMode = false

    func connect(to host: String, port: UInt16, isUSB: Bool) {
        self.isUSBMode = isUSB
        stop()

        if isUSB {
            // USB Muxd Mode (TCP Server waiting for PC)
            startTCPServer(port: port)
        } else {
            // WLAN Mode (UDP Client sending to PC)
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
        print("[VideoStreamClient-UDP] Started")
    }

    private func startTCPServer(port: UInt16) {
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            
            // TCP Parameter - optimiert für Latency
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            tcpListener = try NWListener(using: params, on: nwPort)
            
            tcpListener?.stateUpdateHandler = { state in
                print("[VideoStreamClient-TCPServer] State: \(state)")
            }
            
            tcpListener?.newConnectionHandler = { [weak self] newConnection in
                print("[VideoStreamClient-TCPServer] New connection from \(newConnection.endpoint)")
                self?.handleNewTCPConnection(newConnection)
            }
            
            tcpListener?.start(queue: queue)
            print("[VideoStreamClient-TCPServer] Listening on port \(port) for USBMuxd PC connection...")
        } catch {
            print("[VideoStreamClient-TCPServer] Failed to create listener: \(error)")
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

    /// Sendet einen Annex-B H.264-Frame.
    /// UDP für WLAN, TCP für natives USB-Kabel.
    func send(frameData: Data) {
        if isUSBMode {
            guard let conn = tcpClientConnection else { return }
            
            // Bei TCP müssen wir dem Decoder auf Windows-Seite sagen, wie groß ein Frame ist.
            // Framing: 4-Byte Length Header + H.264 Payload (Typisch für TCP Video Streams)
            var length = UInt32(frameData.count).littleEndian
            var payload = Data(bytes: &length, count: 4)
            payload.append(frameData)
            
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error = error {
                    print("[VideoStreamClient-TCPServer] Send error: \(error)")
                }
            })
        } else {
            // WLAN UDP
            guard let conn = udpConnection else { return }
            conn.send(content: frameData, completion: .contentProcessed { error in
                // Mute errors on high spam UDP
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

