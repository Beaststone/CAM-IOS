import AVFoundation
import Combine

final class CameraSessionManager: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    let sampleBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    private let queue = DispatchQueue(label: "camera.session.queue")

    private var currentDevicePosition: AVCaptureDevice.Position = .back

    override init() {
        super.init()
        configureSession()
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
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func switchCamera() {
        currentDevicePosition = (currentDevicePosition == .back) ? .front : .back
        configureSession()
    }

    func apply(config: StreamConfig) {
        session.beginConfiguration()
        if config.width >= 1920 {
            session.sessionPreset = .hd1920x1080
        } else if config.width >= 1280 {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .vga640x480
        }
        session.commitConfiguration()

        if let device = currentDevice(), let format = bestFormat(for: device, config: config) {
            try? device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        }
    }

    func reconfigure() {
        configureSession()
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
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
    }

    private func currentDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera,
                                for: .video,
                                position: currentDevicePosition)
    }

    private func bestFormat(for device: AVCaptureDevice, config: StreamConfig) -> AVCaptureDevice.Format? {
        device.formats
            .filter { $0.formatDescription.dimensions.width >= config.width }
            .sorted { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }
            .first
    }
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleBufferPublisher.send(sampleBuffer)
    }
}

