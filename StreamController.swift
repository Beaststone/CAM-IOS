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

            let mode = self.appState?.connectionMode ?? .wifi
            let pcIP = mode == .usb ? "172.20.10.2" : "192.168.2.229"
            
            print("[StreamController] Mode: \(mode). Connecting to PC at \(pcIP):5000 and \(pcIP):5960")
            
            let isUSB = (mode == .usb)
            self.encoder.isUSBMode = isUSB

            // FIX: Vorherige Listener hart beenden bevor wir neu binden (verhindert Error 48 Address already in use)
            self.videoClient.stop()
            self.controlClient.disconnect()

            self.videoClient.connect(to: pcIP, port: 5000, isUSB: isUSB)
            self.controlClient.connect(to: pcIP, port: 5960, isUSB: isUSB)
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
        var adjustedConfig = config
        
        // ORIENTATION FIX: Wenn das Handy hochkant gehalten wird, müssen wir Breite und Höhe tauschen
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let orientation = windowScene?.interfaceOrientation ?? .portrait
        
        if orientation.isPortrait && config.width > config.height {
            adjustedConfig.width = config.height
            adjustedConfig.height = config.width
            print("[StreamController] Porträt-Modus erkannt: Tausche Auflösung zu \(adjustedConfig.width)x\(adjustedConfig.height)")
        } else if orientation.isLandscape && config.width < config.height {
            adjustedConfig.width = config.height
            adjustedConfig.height = config.width
            print("[StreamController] Querformat erkannt: Tausche Auflösung zu \(adjustedConfig.width)x\(adjustedConfig.height)")
        }

        controlClient.sendConfig(adjustedConfig)
        cameraManager.apply(config: adjustedConfig)
        encoder.update(config: adjustedConfig)
        
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