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
        print("[StreamController] Init")
        setupPipelines()
        
        // NEU: Beobachtet Drehungen des Handys und aktualisiert den Kamera-Output
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[StreamController] Orientation changed, updating camera output...")
            self?.cameraManager.updateVideoOrientation()
        }
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    func start() {
        print("[StreamController] Starting...")
        UIApplication.shared.isIdleTimerDisabled = true
        cameraManager.requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                print("[StreamController] Camera access denied")
                self.appState?.connectionState = .error("Kamera-Zugriff verweigert")
                return
            }

            print("[StreamController] Camera access granted, configuring...")
            self.cameraManager.reconfigure()
            
            // NEU: Vor dem Start sicherstellen, dass die Orientierung korrekt ist
            self.cameraManager.updateVideoOrientation()
            
            self.cameraManager.start()

            let pcIP = "192.168.2.229"
            print("[StreamController] Connecting to PC at \(pcIP):5000 and \(pcIP):5960")
            self.videoClient.connect(to: pcIP, port: 5000)
            self.controlClient.connect(to: pcIP, port: 5960)
        }
    }

    func stop() {
        print("[StreamController] Stopping")
        appState?.connectionState = .idle
        appState?.isScreenDimmed = false
        cameraManager.stop()
        encoder.stop()
        videoClient.stop()
        controlClient.disconnect()
        UIApplication.shared.isIdleTimerDisabled = false
        cancelDimTimer()
        print("[StreamController] Stopped")
    }

    func sendConfig(_ config: StreamConfig) {
        controlClient.sendConfig(config)
        cameraManager.apply(config: config)
        encoder.update(config: config)
        
        // Auch bei neuen Konfigurationen die Orientierung prüfen
        cameraManager.updateVideoOrientation()
        
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
        print("[StreamController] Setting up pipelines...")
        cameraManager.sampleBufferPublisher
            .receive(on: encoder.queue)
            .sink { [weak self] sampleBuffer in
                self?.encoder.encode(sampleBuffer: sampleBuffer)
            }
            .store(in: &cancellables)

        encoder.onEncoded = { [weak self] data, _ in
            // Print entfernt für bessere Performance, nur bei Debugging aktivieren
            // print("[StreamController] Sending \(data.count) bytes")
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
                print("[StreamController] Searching for PC")
                appState.connectionState = .searching
            case .connected(let pcName):
                print("[StreamController] Connected to \(pcName)")
                appState.connectionState = .connected
                appState.pcName = pcName
                self.resetDimTimer()
            case .error(let msg):
                print("[StreamController] Connection error: \(msg)")
                appState.connectionState = .error(msg)
            case .idle:
                print("[StreamController] Idle")
                appState.connectionState = .idle
                appState.pcName = nil
                appState.isScreenDimmed = false
            }
        }
    }
    
    deinit {
        // Observer entfernen, wenn der Controller gelöscht wird
        NotificationCenter.default.removeObserver(self)
    }
}