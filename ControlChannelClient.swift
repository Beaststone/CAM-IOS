import Foundation
import Network
import Combine

enum ControlConnectionState {
    case idle
    case searching
    case connected(pcName: String)
    case error(String)
}

final class ControlChannelClient {
    private var tcpClientConnection: NWConnection?
    private var tcpListener: NWListener?
    private let queue = DispatchQueue(label: "control.channel.client.queue")

    private var isUSBMode = false

    let configPublisher = PassthroughSubject<StreamConfig, Never>()
    let connectionStatePublisher = PassthroughSubject<ControlConnectionState, Never>()

    func connect(to host: String, port: UInt16, isUSB: Bool) {
        self.isUSBMode = isUSB
        disconnect()
        
        connectionStatePublisher.send(.searching)

        if isUSB {
            startTCPServer(port: port)
        } else {
            startTCPClient(host: host, port: port)
        }
    }

    private func startTCPClient(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        
        tcpClientConnection = NWConnection(host: nwHost, port: nwPort, using: params)
        tcpClientConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectionStatePublisher.send(.connected(pcName: host))
                self?.receiveLoop()
            case .failed(let error), .waiting(let error):
                self?.connectionStatePublisher.send(.error(error.localizedDescription))
            default:
                break
            }
        }
        tcpClientConnection?.start(queue: queue)
    }

        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            
            tcpListener = try NWListener(using: params, on: nwPort)
            
            tcpListener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error), .waiting(let error):
                    self?.connectionStatePublisher.send(.error("USB Listener Error: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            
            tcpListener?.newConnectionHandler = { [weak self] newConnection in
                print("[ControlChannelClient] USB Mux Client connected")
                self?.handleNewTCPConnection(newConnection)
            }
            
            tcpListener?.start(queue: queue)
            print("[ControlChannelClient] Listening on USB port \(port)...")
        } catch {
            connectionStatePublisher.send(.error("Failed to start USB listener: \(error.localizedDescription)"))
        }
    }

    private func handleNewTCPConnection(_ connection: NWConnection) {
        tcpClientConnection?.cancel()
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectionStatePublisher.send(.connected(pcName: "USB-PC"))
                self?.receiveLoop()
            case .failed, .cancelled:
                self?.connectionStatePublisher.send(.idle)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        tcpClientConnection = connection
    }

    func sendConfig(_ config: StreamConfig) {
        guard let conn = tcpClientConnection else { return }
        let message: [String: Any] = [
            "type": "config",
            "width": config.width,
            "height": config.height,
            "fps": config.fps
        ]
        if let data = try? JSONSerialization.data(withJSONObject: message, options: []) {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receiveLoop() {
        tcpClientConnection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handle(data: data)
            }
            if error == nil && !isComplete {
                self?.receiveLoop()
            }
        }
    }

    private func handle(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "config",
           let width = json["width"] as? Int,
           let height = json["height"] as? Int,
           let fps = json["fps"] as? Int {
            let cfg = StreamConfig(width: width, height: height, fps: fps)
            configPublisher.send(cfg)
        }
    }

    func disconnect() {
        tcpClientConnection?.cancel()
        tcpClientConnection = nil
        
        tcpListener?.cancel()
        tcpListener = nil
        
        connectionStatePublisher.send(.idle)
    }
}

