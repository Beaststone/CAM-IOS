import Foundation
import AVFoundation
import VideoToolbox

/// Hardware-H.264-Encoder für iPhone-Kamera.
/// - Nimmt `CMSampleBuffer` Frames entgegen und liefert Annex-B H.264 NALUs.
/// Optimiert für 4K/2K-Streaming und maximale Stabilität (Iriun-Style).
final class H264Encoder {
    let queue = DispatchQueue(label: "h264.encoder.queue")
    private var compressionSession: VTCompressionSession?
    var config: StreamConfig = .defaultConfig

    var isUSBMode: Bool = false {
        didSet {
            if isUSBMode != oldValue {
                print("[H264Encoder] Switched to USB Mode: \(isUSBMode)")
            }
        }
    }

    /// Wird bei jedem encodierten Frame aufgerufen.
    var onEncoded: ((Data, Bool) -> Void)?

    init() {
        print("[H264Encoder] Init")
        setupSession()
    }

    func update(config: StreamConfig) {
        queue.async { [weak self] in
            guard let self = self else { return }
            print("[H264Encoder] Updating config: \(config.width)x\(config.height) @ \(config.fps)fps")
            self.config = config
            self.setupSession()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.internalStop()
        }
    }

    private func internalStop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .positiveInfinity)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            print("[H264Encoder] Stopped")
        }
    }

    private func setupSession() {
        internalStop()

        let width = Int32(config.width)
        let height = Int32(config.height)
        let useHEVC = config.useHEVC ?? true

        // SPEZIFIKATION FÜR ULTRA-LOW LATENCY RATE CONTROL
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        var session: VTCompressionSession?
        let codec = useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                               width: width,
                                               height: height,
                                               codecType: codec,
                                               encoderSpecification: encoderSpec as CFDictionary,
                                               imageBufferAttributes: nil,
                                               compressedDataAllocator: nil,
                                               outputCallback: compressionOutputCallback,
                                               refcon: Unmanaged.passUnretained(self).toOpaque(),
                                               compressionSessionOut: &session)

        guard status == noErr, let session = session else {
            print("[H264Encoder] Failed to create session: \(status). Falling back...")
            if useHEVC { 
                var newConfig = config
                newConfig.useHEVC = false
                self.config = newConfig
                setupH264Session() 
            }
            return
        }

        compressionSession = session

        // --- PROFESSINAL TUNING FÜR WLAN & 4K ---
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: config.fps))
        
        // Rolling Intra Refresh (Essentiell für WLAN/UDP Stabilität)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 0 as CFNumber) 
        VTSessionSetProperty(session, key: "ReferenceRefreshPass" as CFString, value: kCFBooleanTrue)
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        if useHEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        
        // Bitrate-Management
        let bitRate: Int
        if isUSBMode {
            bitRate = config.width >= 3840 ? 40_000_000 : (config.width >= 2560 ? 28_000_000 : 18_000_000)
        } else {
            // WLAN: HEVC ist effizienter, wir können die Bitrate moderat halten für Stabilität
            bitRate = config.width >= 3840 ? 25_000_000 : (config.width >= 2560 ? 15_000_000 : 10_000_000)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)

        let byteLimit = (bitRate * 12 / 10) / 8 // 1.2x Puffer gegen Spikes
        let limit = [byteLimit, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus == noErr {
            print("[H264Encoder] \(useHEVC ? "HEVC" : "H.264") Session ready: \(width)x\(height) @ \(config.fps)fps (\(bitRate/1000000) Mbps)")
        } else {
            print("[H264Encoder] Prepare failed: \(prepareStatus)")
            compressionSession = nil // Zurücksetzen wenn Prepare fehlschlägt
        }
    }

    private func setupH264Session() {
        // Diese Methode wird nur als letzter Fallback gerufen
        setupSession() 
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

    if isKeyframe {
        var parameterSetCount = 0
        var status: OSStatus
        
        // HEVC (H.265) hat 3 Parameter-Sets: VPS, SPS, PPS
        // H.264 hat 2 Parameter-Sets: SPS, PPS
        if encoder.config.useHEVC ?? true {
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        } else {
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        }
        
        if status == noErr {
            for i in 0..<parameterSetCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if encoder.config.useHEVC ?? true {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                
                if let p = ptr {
                    nalData.append(contentsOf: [0, 0, 0, 1])
                    nalData.append(p, count: size)
                }
            }
        }
    }

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
            
            nalData.append(contentsOf: [0, 0, 0, 1])
            let naluPtr = UnsafeRawPointer(baseAddress + offset + 4).assumingMemoryBound(to: UInt8.self)
            nalData.append(naluPtr, count: Int(naluLength))
            
            offset += Int(naluLength) + 4
        }
    }

    if !nalData.isEmpty {
        encoder.onEncoded?(nalData, isKeyframe)
    }
}