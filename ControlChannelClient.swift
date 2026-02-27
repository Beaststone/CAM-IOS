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
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "control.channel.client.queue")

    let configPublisher = PassthroughSubject<StreamConfig, Never>()
    let connectionStatePublisher = PassthroughSubject<ControlConnectionState, Never>()

    func connect(to host: String, port: UInt16) {
        connectionStatePublisher.send(.searching)
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        connection = NWConnection(host: nwHost, port: nwPort, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectionStatePublisher.send(.connected(pcName: host))
                self?.receiveLoop()
            case .failed(let error):
                self?.connectionStatePublisher.send(.error(error.localizedDescription))
            case .waiting(let error):
                self?.connectionStatePublisher.send(.error(error.localizedDescription))
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    func sendConfig(_ config: StreamConfig) {
        guard let conn = connection else { return }
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
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
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
        connection?.cancel()
        connection = nil
        connectionStatePublisher.send(.idle)
    }
}

