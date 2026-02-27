import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var controller: StreamController?
    @State private var isStreaming = false

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Text(titleText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top, 16)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Echte Kamera-Preview
                if let controller = controller {
                    CameraPreview(session: controller.cameraManager.session)
                        .aspectRatio(9.0/16.0, contentMode: .fit)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding()
                } else {
                    // Platzhalter während nicht verbunden
                    ZStack {
                        Color.black.opacity(0.8)
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.5))
                            Text("Kamera-Vorschau")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .aspectRatio(9.0/16.0, contentMode: .fit)
                    .cornerRadius(16)
                    .padding()
                }

                // Streaming Button
                Button(action: toggleStreaming) {
                    Text(isStreaming ? "Stop Streaming" : "Start Streaming")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(isStreaming ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(appState.connectionState == .searching || appState.connectionState == .idle)

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

    private func toggleStreaming() {
        if isStreaming {
            controller?.stop()
            controller = nil
            isStreaming = false
        } else {
            let newController = StreamController()
            newController.attach(appState: appState)
            newController.start()
            self.controller = newController
            isStreaming = true
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
                return "Verbunden mit \(name)"
            }
            return "Verbindung aktiv"
        case .error(let msg):
            return "Fehler: \(msg)"
        }
    }
}
