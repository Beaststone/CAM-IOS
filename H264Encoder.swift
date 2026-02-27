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
        setupSession()
    }

    func update(config: StreamConfig) {
        self.config = config
        setupSession()
    }

    func stop() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    private func setupSession() {
        stop()

        let width = Int32(config.width)
        let height = Int32(config.height)

        VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                   width: width,
                                   height: height,
                                   codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil,
                                   imageBufferAttributes: nil,
                                   compressedDataAllocator: nil,
                                   outputCallback: compressionOutputCallback,
                                   refcon: Unmanaged.passUnretained(self).toOpaque(),
                                   compressionSessionOut: &compressionSession)

        guard let session = compressionSession else { return }

        // Realtime, Hardware-Encoding
        VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFTypeRef)
        VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)

        // Keyframe-Intervall (z.B. alle 2 Sekunden)
        let keyFrameInterval = config.fps * 2
        VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyFrameInterval as CFTypeRef)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flags = VTEncodeInfoFlags()

        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: imageBuffer,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &flags)
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
        return
    }

    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()

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
        }
        if let ppsPtr = ppsPointer {
            nalData.append(startCode, count: 4)
            nalData.append(ppsPtr, count: ppsSize)
        }
    }

    // Encodierte NALUs aus dem BlockBuffer lesen (Länge + NALU)
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: nil,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
    guard status == kCMBlockBufferNoErr, let baseAddress = dataPointer else { return }

    var bufferOffset = 0
    let headerLength = 4 // 4-Byte NALU-Längenpräfix

    while bufferOffset + headerLength < totalLength {
        var naluLength: UInt32 = 0
        memcpy(&naluLength, baseAddress + bufferOffset, headerLength)
        naluLength = CFSwapInt32BigToHost(naluLength)

        let totalNALULength = Int(naluLength)
        let startCode: [UInt8] = [0, 0, 0, 1]
        nalData.append(startCode, count: 4)
        nalData.append(baseAddress + bufferOffset + headerLength, count: totalNALULength)

        bufferOffset += headerLength + totalNALULength
    }

    if !nalData.isEmpty {
        encoder.onEncoded?(nalData, isKeyframe)
    }
}

