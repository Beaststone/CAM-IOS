import Foundation

enum ConnectionState {
    case idle
    case searching
    case connected
    case error(String)
}

struct StreamConfig: Codable {
    var width: Int
    var height: Int
    var fps: Int

    static let defaultConfig = StreamConfig(width: 1280, height: 720, fps: 30)
}

