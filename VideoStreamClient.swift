import Foundation
import Network

final class VideoStreamClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "video.stream.client.queue")

    func connect(to host: String, port: UInt16) {
        print("[VideoStreamClient] Connecting to \(host):\(port)...")
        queue.async { [weak self] in
            let nwHost = NWEndpoint.Host(host)
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let params = NWParameters.udp
            self?.connection = NWConnection(host: nwHost, port: nwPort, using: params)
            self?.connection?.stateUpdateHandler = { state in
                print("[VideoStreamClient] Connection state: \(state)")
            }
            self?.connection?.start(queue: self?.queue ?? DispatchQueue.main)
            print("[VideoStreamClient] Connection started")
        }
    }

    /// Sendet einen Annex-B H.264-Frame als einzelne UDP-Nachricht.
    func send(frameData: Data) {
        guard let conn = connection else { 
            print("[VideoStreamClient] ERROR: No connection!")
            return 
        }
        queue.async {
            print("[VideoStreamClient] Sending \(frameData.count) bytes")
            conn.send(content: frameData, completion: .contentProcessed { error in
                if let error = error {
                    print("[VideoStreamClient] Send error: \(error)")
                }
            })
        }
    }

    func stop() {
        print("[VideoStreamClient] Stopping...")
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    deinit {
        print("[VideoStreamClient] Deinit")
        stop()
    }
}

