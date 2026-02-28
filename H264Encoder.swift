import Foundation
import AVFoundation
import VideoToolbox

/// Hardware-H.264-Encoder für iPhone-Kamera.
/// - Nimmt `CMSampleBuffer` Frames entgegen und liefert Annex-B H.264 NALUs.
/// Optimiert für 4K-Streaming und maximale Stabilität (Iriun-Style).
final class H264Encoder {
    let queue = DispatchQueue(label: "h264.encoder.queue")
    private var compressionSession: VTCompressionSession?
    private var config: StreamConfig = .defaultConfig

    /// Wird bei jedem encodierten Frame aufgerufen.
    var onEncoded: ((Data, Bool) -> Void)?

    init() {
        print("[H264Encoder] Init")
        setupSession()
    }

    func update(config: StreamConfig) {
        print("[H264Encoder] Updating config: \(config.width)x\(config.height) @ \(config.fps)fps")
        self.config = config
        setupSession()
    }

    func stop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .positiveInfinity)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            print("[H264Encoder] Stopped")
        }
    }

    private func setupSession() {
        stop()

        let width = Int32(config.width)
        let height = Int32(config.height)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                               width: width,
                                               height: height,
                                               codecType: kCMVideoCodecType_H264,
                                               encoderSpecification: nil,
                                               imageBufferAttributes: nil,
                                               compressedDataAllocator: nil,
                                               outputCallback: compressionOutputCallback,
                                               refcon: Unmanaged.passUnretained(self).toOpaque(),
                                               compressionSessionOut: &session)

        guard status == noErr, let session = session else {
            print("[H264Encoder] Failed to create session: \(status)")
            return
        }

        compressionSession = session

        // --- IRIUN-LEVEL TUNING FÜR 4K STABILITÄT ---
        
        // 1. Echtzeit-Modus: Minimiert Verzögerung (sehr wichtig für Webcams)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // 2. Erwartete Framerate setzen
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: config.fps))
        
        // 3. Low Latency: Verhindert das Umordnen von Frames (keine B-Frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // 4. High Profile: Ermöglicht bessere Kompression bei 4K Auflösung
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // 5. Aggressive Bitratenkontrolle: 
        // 15 Mbps ist ein sehr guter Wert für 4K über WLAN (scharf aber stabil).
        let bitRate = 15_000_000 
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)

        // 6. Daten-Limit (Das Sicherheitsnetz gegen Handy-Abstürze):
        // Verhindert, dass kurzzeitig zu viele Daten den RAM oder das WLAN fluten.
        let limit = [bitRate / 8, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)

        // 7. GOP-Size (Keyframe-Intervall): 
        // Nur alle 3 Sekunden ein schweres Vollbild spart massiv Bandbreite.
        let keyFrameInterval = config.fps * 3
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyFrameInterval))

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus == noErr {
            print("[H264Encoder] Session ready für 4K: \(width)x\(height) @ \(config.fps)fps")
        } else {
            print("[H264Encoder] Prepare failed: \(prepareStatus)")
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(session,
                                                    imageBuffer: imageBuffer,
                                                    presentationTimeStamp: pts,
                                                    duration: .invalid,
                                                    frameProperties: nil,
                                                    sourceFrameRefcon: nil,
                                                    infoFlagsOut: &flags)

        if status != noErr {
            print("[H264Encoder] Encode failed: \(status)")
        }
    }
}

// MARK: - VTCompression Callback

private func compressionOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
                                       sourceFrameRefCon: UnsafeMutableRawPointer?,
                                       status: OSStatus,
                                       infoFlags: VTEncodeInfoFlags,
                                       sampleBuffer: CMSampleBuffer?) {
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else {
        return
    }

    guard let outputCallbackRefCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()

    // Prüfen ob es ein Keyframe ist
    let isKeyframe: Bool
    if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
       let attachment = attachmentsArray.first {
        let notSync = (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        isKeyframe = !notSync
    } else {
        isKeyframe = false
    }

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    var nalData = Data()

    // SPS/PPS bei Keyframes voranstellen
    if isKeyframe {
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        
        for i in 0..<parameterSetCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p = ptr {
                nalData.append(contentsOf: [0, 0, 0, 1]) // Start Code
                nalData.append(p, count: size)
            }
        }
    }

    // NALUs extrahieren
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    
    CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    
    if let baseAddress = dataPointer {
        var offset = 0
        while offset < totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, baseAddress + offset, 4)
            naluLength = CFSwapInt32BigToHost(naluLength)
            
            nalData.append(contentsOf: [0, 0, 0, 1]) // Start Code
            let naluPtr = UnsafeRawPointer(baseAddress + offset + 4).assumingMemoryBound(to: UInt8.self)
            nalData.append(naluPtr, count: Int(naluLength))
            
            offset += Int(naluLength) + 4
        }
    }

    if !nalData.isEmpty {
        encoder.onEncoded?(nalData, isKeyframe)
    }
}

