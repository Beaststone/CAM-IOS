import Foundation
import Combine
import UIKit

final class StreamController: ObservableObject {
    let cameraManager = CameraSessionManager()
    private let encoder = H264Encoder()
    private let videoClient = VideoStreamClient()
    private let controlClient = ControlChannelClient()
    private var cancellables = Set<AnyCancellable>()

    private var dimTimer: Timer?
    private weak var appState: AppState?

    init() {
        setupPipelines()
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        cameraManager.requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.appState?.connectionState = .error("Kamera-Zugriff nicht erlaubt. Bitte in iOS Einstellungen freigeben.")
                return
            }

            self.cameraManager.reconfigure()
            self.cameraManager.start()

            // Platzhalter: feste Ziel-IP/Port, später per Discovery setzen
            self.videoClient.connect(to: "192.168.2.229", port: 5000) // muss zur PC-IP passen
            self.controlClient.connect(to: "192.168.2.229", port: 5960)
        }
    }

    func stop() {
        cameraManager.stop()
        encoder.stop()
        videoClient.stop()
        controlClient.disconnect()
        UIApplication.shared.isIdleTimerDisabled = false
        cancelDimTimer()
    }

    func sendConfig(_ config: StreamConfig) {
        controlClient.sendConfig(config)
        cameraManager.apply(config: config)
        encoder.update(config: config)
        resetDimTimer()
    }

    func resetDimTimer() {
        cancelDimTimer()
        appState?.isScreenDimmed = false
        dimTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.appState?.isScreenDimmed = true
        }
    }

    private func cancelDimTimer() {
        dimTimer?.invalidate()
        dimTimer = nil
    }

    private func setupPipelines() {
        cameraManager.sampleBufferPublisher
            .receive(on: encoder.queue)
            .sink { [weak self] sampleBuffer in
                self?.encoder.encode(sampleBuffer: sampleBuffer)
            }
            .store(in: &cancellables)

        // Encodierte H.264-Frames direkt per UDP senden
        encoder.onEncoded = { [weak self] data, _ in
            self?.videoClient.send(frameData: data)
        }

        controlClient.configPublisher
            .sink { [weak self] config in
                self?.sendConfig(config)
            }
            .store(in: &cancellables)

        controlClient.connectionStatePublisher
            .sink { [weak self] state in
                self?.handleConnectionState(state)
            }
            .store(in: &cancellables)
    }

    private func handleConnectionState(_ state: ControlConnectionState) {
        guard let appState = appState else { return }
        DispatchQueue.main.async {
            switch state {
            case .searching:
                appState.connectionState = .searching
            case .connected(let pcName):
                appState.connectionState = .connected
                appState.pcName = pcName
                self.resetDimTimer()
            case .error(let msg):
                appState.connectionState = .error(msg)
            case .idle:
                appState.connectionState = .idle
                appState.pcName = nil
                appState.isScreenDimmed = false
            }
        }
    }
}

