import SwiftUI
import AVFoundation


struct CameraPreviewRepresentable: UIViewRepresentable {
    var session: AVCaptureSession

    // 1. Die interne Hilfsklasse für das Layout-Management
    class CameraView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        // Diese Methode wird vom System aufgerufen, sobald das Handy gedreht wird
        override func layoutSubviews() {
            super.layoutSubviews()
            
            guard let layer = previewLayer else { return }
            
            // Frame an die neue Größe anpassen
            layer.frame = self.bounds
            
            // Die interne Video-Ausrichtung korrigieren
            if let connection = layer.connection, connection.isVideoOrientationSupported {
                let scenes = UIApplication.shared.connectedScenes
                let windowScene = scenes.first as? UIWindowScene
                let orientation = windowScene?.interfaceOrientation ?? .portrait
                
                // Mapping von UI-Orientierung zu Video-Orientierung
                switch orientation {
                case .portrait:
                    connection.videoOrientation = .portrait
                case .landscapeLeft:
                    connection.videoOrientation = .landscapeLeft
                case .landscapeRight:
                    connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown:
                    connection.videoOrientation = .portraitUpsideDown
                @unknown default:
                    connection.videoOrientation = .portrait
                }
            }
        }
    }

    // 2. Erstellung der View
    func makeUIView(context: Context) -> UIView {
        let view = CameraView()
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        
        // .resizeAspectFill sorgt für echtes Vollbild (streckt/füllt alles aus)
        previewLayer.videoGravity = .resizeAspectFill
        
        view.layer.addSublayer(previewLayer)
        view.previewLayer = previewLayer

        return view
    }

    // 3. Update-Zyklus von SwiftUI
    func updateUIView(_ uiView: UIView, context: Context) {
        // Hier stellen wir sicher, dass bei jeder Änderung das Layout neu berechnet wird
        DispatchQueue.main.async {
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
        }
    }
}

    private func updateOrientation(_ layer: AVCaptureVideoPreviewLayer) {
        // Holen der aktuellen Fenster-Szene für die Orientierung
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let orientation = windowScene?.interfaceOrientation ?? .portrait

        if let connection = layer.connection, connection.isVideoOrientationSupported {
            switch orientation {
            case .portrait:
                connection.videoOrientation = .portrait
            case .landscapeLeft:
                connection.videoOrientation = .landscapeLeft
            case .landscapeRight:
                connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                connection.videoOrientation = .portraitUpsideDown
            @unknown default:
                connection.videoOrientation = .portrait
            }
        }
    }
}
extension UIInterfaceOrientation {
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        @unknown default: return .portrait
        }
    }
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var controller: StreamController?
    @State private var isStreaming = false

    var body: some View {
        ZStack {
            // KAMERA IMMER ANZEIGEN - FULLSCREEN
            if let controller = controller {
                CameraPreviewRepresentable(session: controller.cameraManager.session)
                    .ignoresSafeArea()
                    .edgesIgnoringSafeArea(.all)
            }

            // TOP BUTTONS OVERLAY
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Camera Switch Button (links)
                    Button(action: { switchCamera() }) {
                        Image(systemName: "camera.rotate.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.top, 12)
                    .padding(.leading, 12)

                    Spacer()

                    // X Button wenn verbunden (rechts)
                    if appState.connectionState == .connected {
                        Button(action: { disconnectStreaming() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.red.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                    }
                }
                Spacer()
            }

            // BOTTOM OVERLAY - nur wenn NICHT verbunden
            if appState.connectionState != .connected {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 16) {
                        // Info Box
                        VStack(spacing: 8) {
                            Text(titleText)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Text(subtitleText)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)

                        // Start Button
                        Button(action: startStreaming) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Start Streaming")
                                    .font(.system(.body, design: .rounded))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(appState.connectionState == .searching)
                        .opacity(appState.connectionState == .searching ? 0.6 : 1.0)

                        // Status Indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(statusMessage)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            if controller == nil {
                let newController = StreamController()
                newController.attach(appState: appState)
                self.controller = newController

                // Kamera sofort starten (aber NICHT mit PC verbinden!)
                newController.cameraManager.requestCameraAccess { [weak newController] granted in
                    guard let newController = newController else { return }
                    if granted {
                        DispatchQueue.main.async {
                            print("[ContentView] Camera access granted, configuring...")
                            newController.cameraManager.reconfigure()
                            newController.cameraManager.start()
                            print("[ContentView] Camera started")
                        }
                    } else {
                        print("[ContentView] Camera access denied")
                    }
                }
            }
        }
    }

    private func startStreaming() {
        if let existingController = controller {
            existingController.start()
            isStreaming = true
        } else {
            let newController = StreamController()
            newController.attach(appState: appState)
            newController.start()
            self.controller = newController
            isStreaming = true
        }
    }

    private func disconnectStreaming() {
        controller?.stop()
        isStreaming = false
    }

    private func switchCamera() {
        print("[ContentView] Switching camera...")
        controller?.cameraManager.switchCamera()
    }

    private var statusMessage: String {
        switch appState.connectionState {
        case .idle:
            return "Nicht verbunden"
        case .searching:
            return "Wird gesucht..."
        case .connected:
            return "Verbunden"
        case .error:
            return "Fehler"
        }
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .idle, .searching:
            return Color.yellow
        case .connected:
            return Color.green
        case .error:
            return Color.red
        }
    }

    private var titleText: String {
        switch appState.connectionState {
        case .idle, .searching:
            return "Kamera-Streamer"
        case .connected:
            return "Mit PC verbunden"
        case .error:
            return "Verbindungsfehler"
        }
    }

    private var subtitleText: String {
        switch appState.connectionState {
        case .idle:
            return "Drücke 'Start' um zu streamen"
        case .searching:
            return "Suche nach PC im gleichen WLAN…"
        case .connected:
            if let name = appState.pcName {
                return "Verbunden mit \(name)"
            }
            return "Verbindung aktiv"
        case .error(let msg):
            return "Fehler: \(msg)"
        }
    }
}

