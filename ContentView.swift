import SwiftUI
import AVFoundation

struct CameraPreviewRepresentable: UIViewRepresentable {
    var session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.connection?.videoOrientation = .portrait
        view.layer.addSublayer(previewLayer)

        // Wichtig: Frame nach dem hinzufügen setzen!
        DispatchQueue.main.async {
            previewLayer.frame = view.bounds
            print("[CameraPreviewRepresentable] Layer frame set to: \(view.bounds)")
            print("[CameraPreviewRepresentable] Session isRunning: \(session.isRunning)")
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = uiView.bounds
            previewLayer.connection?.videoOrientation = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?
                .interfaceOrientation
                .videoOrientation ?? .portrait
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
            // KAMERA IMMER ANZEIGEN (egal ob connected oder nicht) - FULLSCREEN
            if let controller = controller {
                CameraPreviewRepresentable(session: controller.cameraManager.session)
                    .ignoresSafeArea()
                    .edgesIgnoringSafeArea(.all)
            }

            // OVERLAY: Kamera-Wechsel Button IMMER oben links
            VStack {
                HStack {
                    Button(action: { switchCamera() }) {
                        Image(systemName: "camera.rotate.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                    Spacer()
                }
                Spacer()
            }

            // VOLLBILD wenn verbunden - nur X-Button
            if appState.connectionState == .connected {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { disconnectStreaming() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .padding()
                    }
                    Spacer()
                }
            } else {
                // OVERLAY mit Status & Button wenn NICHT verbunden - ZENTRIERT
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 12) {
                        VStack(spacing: 8) {
                            Text(titleText)
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text(subtitleText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)

                        Button(action: startStreaming) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("Start Streaming")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(appState.connectionState == .searching)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(6)
                    }
                    .padding()
                    .background(Color.black.opacity(0.5))

                    Spacer()
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

