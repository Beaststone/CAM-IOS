import Foundation

enum ConnectionState: Equatable {
    case idle
    case searching
    case connected
    case error(String)
}

struct StreamConfig: Codable {
    var width: Int
    var height: Int
    var fps: Int
    var useHEVC: Bool?
    var bitrate: Int? = nil

    init(width: Int, height: Int, fps: Int, useHEVC: Bool? = true, bitrate: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.useHEVC = useHEVC
        self.bitrate = bitrate
    }

    static let defaultConfig = StreamConfig(width: 1280, height: 720, fps: 30, useHEVC: true, bitrate: 6000000)
}

struct ConfigMessage: Codable {
    let type: String
    let width: Int
    let height: Int
    let fps: Int
    let useHEVC: Bool?
}

enum ConnectionMode: String, CaseIterable {
    case wifi = "WLAN"
    case usb = "USB"
}

