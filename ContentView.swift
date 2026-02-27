import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var controller: StreamController?
    @State private var isStreaming = false

    var body: some View {
        ZStack {
            VStack {
                Text(titleText)
                    .font(.title2)
                    .padding(.top, 32)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)

                CameraPreviewPlaceholder()
                    .aspectRatio(9.0/16.0, contentMode: .fit)
                    .cornerRadius(16)
                    .padding()

                // Platzhalter für Settings
                Text("Auflösung & FPS werden vom PC gesteuert.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button(isStreaming ? "Stop" : "Start") {
                    if isStreaming {
                        controller?.stop()
                        controller = nil
                        isStreaming = false
                    } else {
                        let newController = StreamController()
                        newController.attach(appState: appState)
                        newController.start()
                        controller = newController
                        isStreaming = true
                    }
                }
                .padding(.top, 12)

                Spacer()
            }

            if appState.isScreenDimmed {
                BlackScreenOverlayView {
                    controller?.resetDimTimer()
                }
            }
        }
        .onDisappear {
            controller?.stop()
            controller = nil
            isStreaming = false
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
            return "Warte auf Verbindung von deinem PC."
        case .searching:
            return "Suche nach PC im gleichen WLAN…"
        case .connected:
            if let name = appState.pcName {
                return "Verbunden mit \(name)."
            }
            return "Verbindung aktiv."
        case .error(let msg):
            return "Fehler: \(msg)"
        }
    }
}

struct CameraPreviewPlaceholder: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
            Text("Kamera-Vorschau (AVCaptureSession in Xcode anbinden)")
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding()
        }
    }
}

