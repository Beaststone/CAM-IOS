import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var connectionState: ConnectionState = .idle
    @Published var streamConfig = StreamConfig.defaultConfig
    @Published var isScreenDimmed: Bool = false
    @Published var pcName: String? = nil
    @Published var connectionMode: ConnectionMode = .wifi
}

