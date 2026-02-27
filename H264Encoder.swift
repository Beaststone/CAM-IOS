import Foundation
import AVFoundation
import VideoToolbox

/// Hardware-H.264-Encoder für iPhone-Kamera.
/// - Nimmt `CMSampleBuffer` Frames entgegen und liefert Annex-B H.264 NALUs (inkl. SPS/PPS bei Keyframes).
final class H264Encoder {
    let queue = DispatchQueue(label: "h264.encoder.queue")
    private var compressionSession: VTCompressionSession?
    private var config: StreamConfig = .defaultConfig

    /// Wird bei jedem encodierten Frame aufgerufen.
    /// - Parameters:
    ///   - data: Annex-B H.264 Bytestrom (ggf. mehrere NALUs).
    ///   - isKeyframe: true, wenn der Frame ein IDR-Keyframe ist.
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

        guard let session = compressionSession else { return }

        // Realtime, Hardware-Encoding
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: config.fps))
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)

        // Keyframe-Intervall (z.B. alle 2 Sekunden)
        let keyFrameInterval = config.fps * 2
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: keyFrameInterval))

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus == noErr {
            print("[H264Encoder] Session ready: \(width)x\(height) @ \(config.fps)fps")
        } else {
            print("[H264Encoder] Prepare failed: \(prepareStatus)")
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[H264Encoder] Missing session or imageBuffer")
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
          CMSampleBufferDataIsReady(sampleBuffer),
          let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
          let attachment = attachmentsArray.first else {
        print("[H264Encoder] Callback error: status=\(status), sampleBuffer=\(sampleBuffer != nil ? "ready" : "nil")")
        return
    }

    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()

    // Keyframe?
    let notSync = (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    let isKeyframe = !notSync

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

    var nalData = Data()

    // SPS/PPS bei Keyframes voranstellen
    if isKeyframe {
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        var ppsCount: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc,
                                                           parameterSetIndex: 0,
                                                           parameterSetPointerOut: &spsPointer,
                                                           parameterSetSizeOut: &spsSize,
                                                           parameterSetCountOut: &spsCount,
                                                           nalUnitHeaderLengthOut: nil)

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc,
                                                           parameterSetIndex: 1,
                                                           parameterSetPointerOut: &ppsPointer,
                                                           parameterSetSizeOut: &ppsSize,
                                                           parameterSetCountOut: &ppsCount,
                                                           nalUnitHeaderLengthOut: nil)

        let startCode: [UInt8] = [0, 0, 0, 1]
        if let spsPtr = spsPointer {
            nalData.append(startCode, count: 4)
            nalData.append(spsPtr, count: spsSize)
            print("[H264Encoder] SPS added: \(spsSize) bytes")
        }
        if let ppsPtr = ppsPointer {
            nalData.append(startCode, count: 4)
            nalData.append(ppsPtr, count: ppsSize)
            print("[H264Encoder] PPS added: \(ppsSize) bytes")
        }
    }

    // Encodierte NALUs aus dem BlockBuffer lesen (Länge + NALU)
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { 
        print("[H264Encoder] No blockBuffer")
        return 
    }

    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: nil,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
    guard status == kCMBlockBufferNoErr, let baseAddress = dataPointer else { 
        print("[H264Encoder] CMBlockBuffer error")
        return 
    }

    var bufferOffset = 0
    let headerLength = 4 // 4-Byte NALU-Längenpräfix

    while bufferOffset + headerLength < totalLength {
        var naluLength: UInt32 = 0
        memcpy(&naluLength, baseAddress + bufferOffset, headerLength)
        naluLength = CFSwapInt32BigToHost(naluLength)

        let totalNALULength = Int(naluLength)
        let startCode: [UInt8] = [0, 0, 0, 1]
        nalData.append(startCode, count: 4)

        // Pointer-Typ konvertieren (Int8 -> UInt8) für append(_:count:)
        let naluPointer = UnsafeRawPointer(baseAddress + bufferOffset + headerLength)
            .assumingMemoryBound(to: UInt8.self)
        nalData.append(naluPointer, count: totalNALULength)

        bufferOffset += headerLength + totalNALULength
    }

    if !nalData.isEmpty {
        print("[H264Encoder] Encoded frame: \(nalData.count) bytes, keyframe=\(isKeyframe)")
        encoder.onEncoded?(nalData, isKeyframe)
    } else {
        print("[H264Encoder] WARNING: Empty nalData after encoding")
    }
}

