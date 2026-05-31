/// `H264Decoder` — instance-based H.264 hardware decoder. Replaces the demo's
/// 4 module-level globals (decompressionSession / formatDescription / spsData /
/// ppsData) with per-instance state, so two decoders can run side-by-side
/// without clobbering each other.
///
/// Two non-obvious correctness fixes from the original demo are baked in here:
///   1. The format description is built with `nalUnitHeaderLength: 4`, which
///      means VT expects AVCC framing (4-byte big-endian length prefix). The
///      demo fed Annex-B framing, causing -12909 on every decode call. Inputs
///      to `feed(naluData:timestamp:)` may be Annex-B; we strip the start code
///      and prepend the length on the way in.
///   2. VTDecompressionSession's *specification* dictionary may not contain
///      property keys (RealTime / ThreadCount / QoSTier). The demo packed them
///      into the spec, producing a config VT could not satisfy. Properties are
///      now applied with `VTSessionSetProperty` after the session exists.
import Foundation
import VideoToolbox
import CoreMedia

public final class H264Decoder {

    public struct Config {
        public var requireHardware: Bool
        public var idrSessionRebuild: Bool
        public var enableEmergencyRecovery: Bool

        public init(
            requireHardware: Bool = false,
            idrSessionRebuild: Bool = true,
            enableEmergencyRecovery: Bool = true
        ) {
            self.requireHardware = requireHardware
            self.idrSessionRebuild = idrSessionRebuild
            self.enableEmergencyRecovery = enableEmergencyRecovery
        }
    }

    public enum DecodeError: Error {
        case sessionNotInitialized
        case formatDescriptionFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case decodeFailed(OSStatus)
    }

    public var onFrame: ((CVImageBuffer, CMTime) -> Void)?

    private var config: Config
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    public init(config: Config = .init()) {
        self.config = config
    }

    deinit {
        invalidate()
    }

    // MARK: - Public API

    /// Provide SPS+PPS NAL payloads (without start codes — Annex-B prefix is
    /// stripped automatically). Must be called before `feed`.
    public func loadParameterSets(sps: Data, pps: Data) throws {
        let cleanSPS = H264Stream.removeStartCode(from: sps)
        let cleanPPS = H264Stream.removeStartCode(from: pps)
        guard !cleanSPS.isEmpty, !cleanPPS.isEmpty else {
            throw DecodeError.formatDescriptionFailed(-1)
        }
        guard cleanSPS.count >= 4 else {
            throw DecodeError.formatDescriptionFailed(-2)
        }
        spsData = cleanSPS
        ppsData = cleanPPS
        try buildFormatDescription(sps: cleanSPS, pps: cleanPPS)
        try createSession()
    }

    /// Decode a single NAL unit. Either Annex-B framed (with start code) or
    /// raw payload — both are normalised to AVCC internally.
    public func feed(naluData: Data, timestamp: CMTime) throws {
        guard session != nil else {
            throw DecodeError.sessionNotInitialized
        }

        var raw = H264Stream.removeStartCode(from: naluData)
        guard !raw.isEmpty else { return }
        H264Stream.fixForbiddenBit(&raw)

        let nalType = raw[0] & 0x1F

        // Convert Annex-B → AVCC: 4-byte big-endian length + payload.
        let length = UInt32(raw.count)
        var avccData = Data(count: 4)
        avccData[0] = UInt8((length >> 24) & 0xFF)
        avccData[1] = UInt8((length >> 16) & 0xFF)
        avccData[2] = UInt8((length >> 8) & 0xFF)
        avccData[3] = UInt8(length & 0xFF)
        avccData.append(raw)

        // Optional IDR session rebuild (preserves the demo's reliability tactic).
        if config.idrSessionRebuild && nalType == 5 {
            invalidate()
            if let s = spsData, let p = ppsData {
                try buildFormatDescription(sps: s, pps: p)
                try createSession()
            }
        }

        try decodeAVCC(buffer: avccData, nalType: nalType, timestamp: timestamp)
    }

    /// Block until VT finishes any in-flight asynchronous frames.
    public func waitForCompletion() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        }
    }

    /// Tear down the decompression session. Idempotent.
    public func invalidate() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDescription = nil
    }

    // MARK: - Internals

    private func buildFormatDescription(sps: Data, pps: Data) throws {
        var fd: CMVideoFormatDescription?
        let parameterSetSizes: [Int] = [sps.count, pps.count]

        let status = pps.withUnsafeBytes { ppsBytes -> OSStatus in
            guard let ppsBase = ppsBytes.baseAddress else { return -1 }
            return sps.withUnsafeBytes { spsBytes -> OSStatus in
                guard let spsBase = spsBytes.baseAddress else { return -1 }
                var pointers: [UnsafePointer<UInt8>?] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self),
                ]
                return pointers.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UnsafePointer<UInt8>.self, capacity: 2) { rebound in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: rebound,
                            parameterSetSizes: parameterSetSizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd
                        )
                    }
                }
            }
        }

        guard status == noErr, let fdValue = fd else {
            throw DecodeError.formatDescriptionFailed(status)
        }
        formatDescription = fdValue
    }

    private func createSession() throws {
        guard let fd = formatDescription else {
            throw DecodeError.formatDescriptionFailed(-3)
        }

        // Empty spec: VT picks the best decoder for the format. See file
        // header for why property keys must NOT live in this dict.
        let spec = NSMutableDictionary()
        if config.requireHardware {
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }

        // Pixel format only — let VT pull dimensions from SPS.
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: H264Decoder.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: spec,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )

        // If hardware was required and creation failed, fall back to no-spec
        // (software-allowed) creation — preserves the demo's tactic.
        if status != noErr && config.requireHardware {
            let softSpec = NSMutableDictionary()
            softSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false
            softSpec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = false
            let retry = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: fd,
                decoderSpecification: softSpec,
                imageBufferAttributes: imageBufferAttributes as CFDictionary,
                outputCallback: &callback,
                decompressionSessionOut: &newSession
            )
            guard retry == noErr, let s = newSession else {
                throw DecodeError.sessionCreationFailed(retry)
            }
            session = s
        } else {
            guard status == noErr, let s = newSession else {
                throw DecodeError.sessionCreationFailed(status)
            }
            session = s
        }

        if let s = session {
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        }
    }

    private func decodeAVCC(buffer avcc: Data, nalType: UInt8, timestamp: CMTime) throws {
        guard let session = session, let fd = formatDescription else {
            throw DecodeError.sessionNotInitialized
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            throw DecodeError.blockBufferFailed(status)
        }

        status = CMBlockBufferReplaceDataBytes(
            with: [UInt8](avcc),
            blockBuffer: bb,
            offsetIntoDestination: 0,
            dataLength: avcc.count
        )
        guard status == kCMBlockBufferNoErr else {
            throw DecodeError.blockBufferFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [avcc.count]
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else {
            throw DecodeError.sampleBufferFailed(status)
        }

        // Mark IDR as keyframe.
        if nalType == 5 {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_IsDependedOnByOthers).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
                )
            }
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: VTDecodeFrameFlags(rawValue: 0),
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if decodeStatus != noErr {
            // Emergency recovery for kVTVideoDecoderMalfunctionErr.
            if decodeStatus == -12909 && config.enableEmergencyRecovery {
                coreLog("解码器故障，执行紧急恢复...", force: true)
                invalidate()
                if let s = spsData, let p = ppsData {
                    try buildFormatDescription(sps: s, pps: p)
                    try createSession()
                }
                return
            }
            throw DecodeError.decodeFailed(decodeStatus)
        }
    }

    // MARK: - VT C callback bridge

    private static let outputCallback: VTDecompressionOutputCallback = { (
        refCon, _, status, _, imageBuffer, pts, _
    ) in
        guard let refCon = refCon else { return }
        guard status == noErr, let imageBuffer = imageBuffer else { return }
        let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
        decoder.onFrame?(imageBuffer, pts)
    }
}
