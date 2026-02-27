import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var controller: StreamController?
    @State private var isStreaming = false

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    Text(titleText)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(subtitleText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 16)

                if let controller = controller {
                    CameraPreview(session: controller.cameraManager.session)
                        .aspectRatio(4.0/3.0, contentMode: .fit)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                        .padding()
                } else {
                    ZStack {
                        Color.black.opacity(0.8)
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white.opacity(0.5))
                            Text("Kamera nicht aktiv")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .cornerRadius(12)
                    .padding()
                }

                VStack(spacing: 8) {
                    Button(action: toggleStreaming) {
                        HStack {
                            Image(systemName: isStreaming ? "stop.circle.fill" : "play.circle.fill")
                            Text(isStreaming ? "Stop Streaming" : "Start Streaming")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(isStreaming ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(appState.connectionState == .searching)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)

                        if let pcName = appState.pcName {
                            Text("PC: \(pcName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                .padding(.horizontal)

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

