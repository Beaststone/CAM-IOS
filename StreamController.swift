import Foundation
import Combine
import UIKit

final class StreamController: ObservableObject {
    let cameraManager = CameraSessionManager()
    private let encoder = H264Encoder()
    private let videoClient = VideoStreamClient()
    private let controlClient = ControlChannelClient()
    private var cancellables = Set<AnyCancellable>()

    private var lastReceivedConfig: StreamConfig?
    private var dimTimer: Timer?
    private weak var appState: AppState?

    init() {
        print("[StreamController] Init")
        setupPipelines()
        
        // ORIENTATION FIX: Beobachtet Drehungen und triggert proaktiv eine Neukonfiguration
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let lastConfig = self.lastReceivedConfig else { return }
            print("[StreamController] Orientation changed, re-applying config...")
            self.sendConfig(lastConfig)
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
            
            let mode = self.appState?.connectionMode ?? .wifi
            let pcIP = mode == .usb ? "172.20.10.2" : "192.168.2.229"
            let isUSB = (mode == .usb)
            
            print("[StreamController] Mode: \(mode). Target: \(pcIP)")
            
            self.encoder.isUSBMode = isUSB

            // FIX: Nur stoppen wenn nötig, um Port-Konflikte zu vermeiden
            self.videoClient.connect(to: pcIP, port: 5000, isUSB: isUSB)
            self.controlClient.connect(to: pcIP, port: 5960, isUSB: isUSB)
            
            self.cameraManager.start()
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
        lastReceivedConfig = nil 
        print("[StreamController] Stopped")
    }

    func sendConfig(_ config: StreamConfig) {
        self.lastReceivedConfig = config
        var adjustedConfig = config
        
        // ORIENTATION FIX: Auflösung proaktiv an die aktuelle Gerätelage anpassen
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let orientation = windowScene?.interfaceOrientation ?? .portrait
        
        let isPortrait = orientation.isPortrait
        
        if isPortrait && config.width > config.height {
            adjustedConfig.width = config.height
            adjustedConfig.height = config.width
            print("[StreamController] Swapping to Portrait: \(adjustedConfig.width)x\(adjustedConfig.height)")
        } else if !isPortrait && config.width < config.height {
            adjustedConfig.width = config.height
            adjustedConfig.height = config.width
            print("[StreamController] Swapping to Landscape: \(adjustedConfig.width)x\(adjustedConfig.height)")
        }

        controlClient.sendConfig(adjustedConfig)
        cameraManager.apply(config: adjustedConfig)
        encoder.update(config: adjustedConfig)
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