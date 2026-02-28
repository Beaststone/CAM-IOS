import AVFoundation
import Combine
import UIKit

final class CameraSessionManager: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    let sampleBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    private let queue = DispatchQueue(label: "camera.session.queue")

    private var currentDevicePosition: AVCaptureDevice.Position = .back
    private var isConfigured = false

    override init() {
        super.init()
    }

    func requestCameraAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    func start() {
        print("[CameraSessionManager] Starting session...")
        if !isConfigured {
            configureSession()
            isConfigured = true
        }
        if !session.isRunning {
            // Session-Start im Hintergrund, um UI-Lags zu vermeiden
            queue.async { [weak self] in
                self?.session.startRunning()
                print("[CameraSessionManager] Session running: \(self?.session.isRunning ?? false)")
            }
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func switchCamera() {
        currentDevicePosition = (currentDevicePosition == .back) ? .front : .back
        reconfigure()
    }

    func apply(config: StreamConfig) {
        session.beginConfiguration()
        
        // --- AUFLÖSUNGS-PRESETS INKL. 4K & 2K ---
        // PHASE 12: Wir priorisieren FPS vor Automatik (Jetzt sicher durch Atomic Reset)
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = .hd1920x1080
        }
        
        session.commitConfiguration()

        // --- PRÄZISES FORMAT- & FPS-TUNING ---
        if let device = currentDevice(), let format = bestFormat(for: device, config: config) {
            do {
                try device.lockForConfiguration()
                
                // Setzt das exakte Format (wichtig für 2K/4K/60FPS)
                device.activeFormat = format
                
                // Defensive FPS-Capping: Nie mehr fordern als das Format kann (verhindert Crashes)
                let targetFPS = Float64(config.fps)
                let maxSupportedFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? targetFPS
                let actualFPS = min(targetFPS, maxSupportedFPS)
                
                // PHASE 7.1: DYNAMISCHER FPS LOCK (SIGABRT FIX)
                // Wir fordern die Dauer basierend auf den tatsächlich ermittelten actualFPS.
                let targetDuration = CMTime(value: 1, timescale: Int32(actualFPS))
                
                // Wir validieren die Dauer gegen die Hardware-Ranges des aktuellen Formats
                if let range = format.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= actualFPS && $0.minFrameRate <= actualFPS }) {
                    let minDuration = range.minFrameDuration
                    let maxDuration = range.maxFrameDuration
                    let safeDuration = CMTimeClampToRange(targetDuration, range: CMTimeRange(start: minDuration, end: maxDuration))
                    
                    device.activeVideoMinFrameDuration = safeDuration
                    device.activeVideoMaxFrameDuration = safeDuration
                    print("[CameraSessionManager] Applied Hardware-Validated Duration: \(safeDuration.seconds)s (FPS: \(actualFPS))")
                } else {
                    // Fallback: Nur setzen wenn wir sicher sind
                    device.activeVideoMinFrameDuration = targetDuration
                    device.activeVideoMaxFrameDuration = targetDuration
                }
                
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                
                // Falls wir doch manuell eingreifen wollen (Thermal Fallback etc.):
                // print("[CameraSessionManager] Ready for 60 FPS (Auto-Exposure)")

                device.unlockForConfiguration()
                print("[CameraSessionManager] Applied: \(config.width)x\(config.height) @ \(actualFPS) FPS (Target: \(config.fps))")
            } catch {
                print("[CameraSessionManager] Configuration Error: \(error)")
            }
        }
    }

    func reconfigure() {
        configureSession()
        isConfigured = true
    }

    private func configureSession() {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }

        guard let device = currentDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        if session.outputs.isEmpty {
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            // Wichtig für Performance: Frames verwerfen, wenn der Encoder zu langsam ist
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        updateVideoOrientation()
        session.commitConfiguration()
    }

    func updateVideoOrientation() {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let orientation = windowScene?.interfaceOrientation ?? .portrait

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            switch orientation {
            case .portrait: connection.videoOrientation = .portrait
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            case .unknown: connection.videoOrientation = .portrait
            @unknown default: connection.videoOrientation = .portrait
            }
        }
    }

    private func currentDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentDevicePosition)
    }

    private func bestFormat(for device: AVCaptureDevice, config: StreamConfig) -> AVCaptureDevice.Format? {
        let reqW = Int32(config.width)
        let reqH = Int32(config.height)
        let reqMin = min(reqW, reqH)
        let targetAspectRatio = Double(max(reqW, reqH)) / Double(min(reqW, reqH))
        let targetFPS = Float64(config.fps)

        // 1. Suche Formate, die die Ziel-FPS unterstützen
        let fpsSupported = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS
            }
        }

        // 2. Suche in diesen Formaten nach der besten Auflösung UND dem besten Seitenverhältnis
        let formatsToSearch = fpsSupported.isEmpty ? device.formats : fpsSupported
        
        let sortedByMatch = formatsToSearch.sorted { f1, f2 in
            let dims1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let dims2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            
            let w1 = min(dims1.width, dims1.height)
            let w2 = min(dims2.width, dims2.height)
            let ar1 = Double(max(dims1.width, dims1.height)) / Double(min(dims1.width, dims1.height))
            let ar2 = Double(max(dims2.width, dims2.height)) / Double(min(dims2.width, dims2.height))
            
            let arDiff1 = abs(ar1 - targetAspectRatio)
            let arDiff2 = abs(ar2 - targetAspectRatio)
            
            // Priorität 1: Seitenverhältnis (WICHTIG gegen Stretching)
            // Wir lassen eine kleine Toleranz (0.05), falls die Auflösung viel besser passt
            if abs(arDiff1 - arDiff2) > 0.05 {
                return arDiff1 < arDiff2
            }
            
            // Priorität 2: Auflösung (Mindestgröße erfüllen)
            let meetsReq1 = w1 >= reqMin
            let meetsReq2 = w2 >= reqMin
            
            if meetsReq1 && !meetsReq2 { return true }
            if meetsReq2 && !meetsReq1 { return false }
            
            // Wenn beide >= oder beide < sind, nimm das, was näher am Ziel ist
            return abs(w1 - reqMin) < abs(w2 - reqMin)
        }

        let best = sortedByMatch.first ?? device.formats.last
        if let b = best {
            let dims = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            print("[CameraSessionManager] Selected format: \(dims.width)x\(dims.height) (Target: \(reqW)x\(reqH))")
        }
        return best
    }
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sampleBufferPublisher.send(sampleBuffer)
    }
}