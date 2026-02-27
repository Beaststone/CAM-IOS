import Foundation
import Network

final class VideoStreamClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "video.stream.client.queue")

    func connect(to host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp
        connection = NWConnection(host: nwHost, port: nwPort, using: params)
        connection?.start(queue: queue)
    }

    /// Sendet einen Annex-B H.264-Frame als einzelne UDP-Nachricht.
    func send(frameData: Data) {
        guard let conn = connection else { return }
        conn.send(content: frameData, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}

