/// Pure-Swift H.264 Sequence Parameter Set parser. Decodes the bitstream
/// syntax defined in ITU-T H.264 spec 7.3.2.1.1 with the semantics from
/// 7.4.2.1.1 — enough to recover frame dimensions, profile/level, and a
/// best-effort fps / B-frame hint without pulling in VideoToolbox or
/// ffmpeg. Emulation prevention bytes (spec 7.4.1.1) are stripped before
/// bit-level decoding.
import Foundation

/// Minimal MSB-first bit reader over a `Data` payload. Internal — only
/// `H264SPSParser` needs it. All read methods clamp at end-of-stream and
/// flag `failed`; callers should bail out if `failed` becomes true.
internal struct BitReader {
    private let bytes: [UInt8]
    private var bitIndex: Int = 0
    private(set) var failed: Bool = false

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    /// Bits remaining from the current cursor.
    var bitsRemaining: Int {
        return max(0, bytes.count * 8 - bitIndex)
    }

    /// Read a single bit as 0/1.
    mutating func readBit() -> UInt32 {
        let byteIdx = bitIndex >> 3
        if byteIdx >= bytes.count {
            failed = true
            return 0
        }
        let bitOffset = 7 - (bitIndex & 7)
        let bit = UInt32((bytes[byteIdx] >> UInt8(bitOffset)) & 0x01)
        bitIndex += 1
        return bit
    }

    /// Read `count` bits (count <= 32) as an unsigned integer, MSB first.
    mutating func readBits(count n: Int) -> UInt32 {
        precondition(n >= 0 && n <= 32, "readBits out of range")
        var value: UInt32 = 0
        for _ in 0..<n {
            value = (value << 1) | readBit()
            if failed { return 0 }
        }
        return value
    }

    /// Unsigned Exp-Golomb (ue(v)) — spec 9.1.
    mutating func readUE() -> UInt32 {
        var zeroes = 0
        while !failed {
            let b = readBit()
            if failed { return 0 }
            if b == 1 { break }
            zeroes += 1
            if zeroes > 32 {
                failed = true
                return 0
            }
        }
        if zeroes == 0 { return 0 }
        let suffix = readBits(count: zeroes)
        if failed { return 0 }
        return (UInt32(1) << UInt32(zeroes)) - 1 + suffix
    }

    /// Signed Exp-Golomb (se(v)) — spec 9.1.1.
    mutating func readSE() -> Int32 {
        let code = readUE()
        if failed { return 0 }
        if code == 0 { return 0 }
        if code & 1 == 1 {
            return Int32((code + 1) >> 1)
        } else {
            return -Int32(code >> 1)
        }
    }

    /// Skip `n` bits without producing a value.
    mutating func skipBits(_ n: Int) {
        bitIndex += n
        if bitIndex > bytes.count * 8 {
            failed = true
        }
    }
}

/// Parsed view of the fields we care about from an H.264 SPS.
public struct H264SPSInfo {
    /// H.264 profile_idc per spec Annex A (66=Baseline, 77=Main, 100=High, …).
    public let profileIdc: Int
    /// H.264 level_idc per spec Annex A; e.g. 30 == Level 3.0.
    public let levelIdc: Int
    /// Cropped frame width in luma samples (after frame_cropping is applied).
    public let width: Int
    /// Cropped frame height in luma samples (after frame_cropping is applied).
    public let height: Int
    /// Best-effort fps from VUI timing_info as `time_scale / (2 * num_units_in_tick)`;
    /// `nil` if VUI / timing_info is absent.
    public let fpsHint: Double?
    /// Profile-based hint only — `true` when `profileIdc` is not in the
    /// baseline-like set {66, 77}. NOT slice-verified; Main can carry B and
    /// High streams can be all-I/P. Confirming requires NAL slice_type inspection.
    public let hasBFramesHint: Bool
    /// chroma_format_idc per spec 6.2 (0=mono, 1=4:2:0, 2=4:2:2, 3=4:4:4).
    /// Defaults to 1 for profiles that omit the field.
    public let chromaFormatIdc: Int
    /// max_num_ref_frames from the SPS (DPB size hint).
    public let numRefFrames: Int

    /// Public memberwise initializer so external test fixtures can construct
    /// `H264SPSInfo` values without going through `parse`.
    public init(
        profileIdc: Int,
        levelIdc: Int,
        width: Int,
        height: Int,
        fpsHint: Double?,
        hasBFramesHint: Bool,
        chromaFormatIdc: Int,
        numRefFrames: Int
    ) {
        self.profileIdc = profileIdc
        self.levelIdc = levelIdc
        self.width = width
        self.height = height
        self.fpsHint = fpsHint
        self.hasBFramesHint = hasBFramesHint
        self.chromaFormatIdc = chromaFormatIdc
        self.numRefFrames = numRefFrames
    }
}

public enum H264SPSParser {

    /// Parse a raw SPS NAL payload (no Annex-B start code; first byte is
    /// the NAL header, e.g. `0x67`). Returns `nil` on malformed input.
    public static func parse(_ spsPayload: Data) -> H264SPSInfo? {
        // Need at least nal_header + profile_idc + constraint_set + level_idc.
        guard spsPayload.count >= 4 else { return nil }

        // Strip the leading NAL header byte; the rest is the RBSP wrapped
        // with emulation prevention bytes. Use Array(...).dropFirst() to be
        // slice-safe regardless of `Data` startIndex.
        let rbspWrapped = Data(Array(spsPayload).dropFirst())
        let rbsp = stripEmulationPrevention(rbspWrapped)
        guard rbsp.count >= 3 else { return nil }

        let bytes = [UInt8](rbsp)
        let profileIdc = Int(bytes[0])
        // bytes[1] holds constraint_set*_flag bits + reserved_zero_2bits.
        let levelIdc = Int(bytes[2])

        // The remaining fields are bit-packed starting after byte 2.
        var reader = BitReader(Data(Array(bytes).dropFirst(3)))

        // seq_parameter_set_id
        _ = reader.readUE()
        if reader.failed { return nil }

        // Profiles that carry the chroma format / bit depth block in SPS.
        let extendedProfiles: Set<Int> = [
            100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135
        ]

        var chromaFormatIdc: Int = 1
        var separateColourPlaneFlag: UInt32 = 0

        if extendedProfiles.contains(profileIdc) {
            chromaFormatIdc = Int(reader.readUE())
            if reader.failed { return nil }
            if chromaFormatIdc == 3 {
                separateColourPlaneFlag = reader.readBit()
                if reader.failed { return nil }
            }
            _ = reader.readUE() // bit_depth_luma_minus8
            _ = reader.readUE() // bit_depth_chroma_minus8
            _ = reader.readBit() // qpprime_y_zero_transform_bypass_flag
            let seqScalingMatrixPresent = reader.readBit()
            if reader.failed { return nil }
            if seqScalingMatrixPresent == 1 {
                let listCount = (chromaFormatIdc != 3) ? 8 : 12
                for i in 0..<listCount {
                    let scalingListPresent = reader.readBit()
                    if reader.failed { return nil }
                    if scalingListPresent == 1 {
                        let size = (i < 6) ? 16 : 64
                        skipScalingList(&reader, size: size)
                        if reader.failed { return nil }
                    }
                }
            }
        }

        _ = reader.readUE() // log2_max_frame_num_minus4
        if reader.failed { return nil }

        let picOrderCntType = reader.readUE()
        if reader.failed { return nil }

        if picOrderCntType == 0 {
            _ = reader.readUE() // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            _ = reader.readBit() // delta_pic_order_always_zero_flag
            _ = reader.readSE()  // offset_for_non_ref_pic
            _ = reader.readSE()  // offset_for_top_to_bottom_field
            let numRefFramesInCycle = reader.readUE()
            if reader.failed { return nil }
            // Spec bounds num_ref_frames_in_pic_order_cnt_cycle to 255.
            let cycle = min(Int(numRefFramesInCycle), 255)
            for _ in 0..<cycle {
                _ = reader.readSE()
            }
        }
        if reader.failed { return nil }

        let numRefFrames = Int(reader.readUE())
        if reader.failed { return nil }

        _ = reader.readBit() // gaps_in_frame_num_value_allowed_flag

        let picWidthInMbsMinus1 = reader.readUE()
        if reader.failed { return nil }
        let picHeightInMapUnitsMinus1 = reader.readUE()
        if reader.failed { return nil }

        let frameMbsOnlyFlag = reader.readBit()
        if reader.failed { return nil }
        if frameMbsOnlyFlag == 0 {
            _ = reader.readBit() // mb_adaptive_frame_field_flag
        }
        _ = reader.readBit() // direct_8x8_inference_flag

        var cropLeft: UInt32 = 0
        var cropRight: UInt32 = 0
        var cropTop: UInt32 = 0
        var cropBottom: UInt32 = 0
        let frameCroppingFlag = reader.readBit()
        if reader.failed { return nil }
        if frameCroppingFlag == 1 {
            cropLeft = reader.readUE()
            cropRight = reader.readUE()
            cropTop = reader.readUE()
            cropBottom = reader.readUE()
            if reader.failed { return nil }
        }

        // VUI — only timing_info is mined for fps.
        var fpsHint: Double? = nil
        let vuiPresent = reader.readBit()
        if reader.failed { return nil }
        if vuiPresent == 1 {
            fpsHint = parseVUITimingFps(&reader)
        }

        // Compute width / height from MB counts minus crop. Formulae
        // derived from spec 7.4.2.1.1 (PicWidthInSamplesL etc.).
        let widthInMbs = Int(picWidthInMbsMinus1) + 1
        let heightInMapUnits = Int(picHeightInMapUnitsMinus1) + 1
        let frameHeightInMbs = (frameMbsOnlyFlag == 1 ? 1 : 2) * heightInMapUnits

        // Sub-sampling factors driven by chroma_format_idc. With
        // separate_colour_plane_flag set the luma plane is sampled
        // independently, so the multipliers fall back to 1.
        let subWidthC: Int
        let subHeightC: Int
        if separateColourPlaneFlag == 1 {
            subWidthC = 1
            subHeightC = 1
        } else {
            switch chromaFormatIdc {
            case 1: subWidthC = 2; subHeightC = 2  // 4:2:0
            case 2: subWidthC = 2; subHeightC = 1  // 4:2:2
            case 3: subWidthC = 1; subHeightC = 1  // 4:4:4
            default: subWidthC = 2; subHeightC = 2
            }
        }

        let cropUnitX: Int
        let cropUnitY: Int
        if chromaFormatIdc == 0 || separateColourPlaneFlag == 1 {
            cropUnitX = 1
            cropUnitY = (frameMbsOnlyFlag == 1) ? 1 : 2
        } else {
            cropUnitX = subWidthC
            cropUnitY = subHeightC * (frameMbsOnlyFlag == 1 ? 1 : 2)
        }

        let rawWidth = widthInMbs * 16
        let rawHeight = frameHeightInMbs * 16
        let width = rawWidth - cropUnitX * (Int(cropLeft) + Int(cropRight))
        let height = rawHeight - cropUnitY * (Int(cropTop) + Int(cropBottom))

        if width <= 0 || height <= 0 { return nil }

        // Baseline (66) and Main (77) traditionally do not encode B
        // slices — main profile actually can, but distinguishing requires
        // slice-level inspection so we fall back to the simple heuristic
        // requested by the API contract.
        let baselineLikeProfiles: Set<Int> = [66, 77]
        let hasBFrames = !baselineLikeProfiles.contains(profileIdc)

        return H264SPSInfo(
            profileIdc: profileIdc,
            levelIdc: levelIdc,
            width: width,
            height: height,
            fpsHint: fpsHint,
            hasBFramesHint: hasBFrames,
            chromaFormatIdc: chromaFormatIdc,
            numRefFrames: numRefFrames
        )
    }

    // MARK: - helpers

    /// Remove emulation prevention bytes per spec 7.4.1.1: any sequence
    /// `00 00 03` inside the NAL RBSP has the trailing `0x03` dropped.
    private static func stripEmulationPrevention(_ data: Data) -> Data {
        let src = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            if i + 2 < src.count && src[i] == 0x00 && src[i + 1] == 0x00 && src[i + 2] == 0x03 {
                out.append(0x00)
                out.append(0x00)
                i += 3
            } else {
                out.append(src[i])
                i += 1
            }
        }
        return Data(out)
    }

    /// Walk over a scaling list without storing the values — spec 7.3.2.1.1.1.
    /// Uses bit-mask `& 0xFF` instead of `% 256` so the spec-required
    /// non-negative wrap holds even if `lastScale + deltaScale` is negative.
    private static func skipScalingList(_ reader: inout BitReader, size: Int) {
        var lastScale: Int32 = 8
        var nextScale: Int32 = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let deltaScale = reader.readSE()
                if reader.failed { return }
                nextScale = (lastScale + deltaScale) & 0xFF
            }
            if nextScale != 0 {
                lastScale = nextScale
            }
        }
    }

    /// Skim VUI parameters far enough to recover `time_scale` /
    /// (`num_units_in_tick` * 2) when timing info is present. Spec
    /// E.1.1. Returns nil if timing info is absent or stream is short.
    private static func parseVUITimingFps(_ reader: inout BitReader) -> Double? {
        // aspect_ratio_info_present_flag
        let aspectPresent = reader.readBit()
        if reader.failed { return nil }
        if aspectPresent == 1 {
            let aspectRatioIdc = reader.readBits(count: 8)
            if reader.failed { return nil }
            if aspectRatioIdc == 255 { // Extended_SAR
                _ = reader.readBits(count: 16)
                _ = reader.readBits(count: 16)
                if reader.failed { return nil }
            }
        }

        let overscanInfoPresent = reader.readBit()
        if reader.failed { return nil }
        if overscanInfoPresent == 1 {
            _ = reader.readBit()
        }

        let videoSignalTypePresent = reader.readBit()
        if reader.failed { return nil }
        if videoSignalTypePresent == 1 {
            _ = reader.readBits(count: 3) // video_format
            _ = reader.readBit()          // video_full_range_flag
            let colourDescPresent = reader.readBit()
            if reader.failed { return nil }
            if colourDescPresent == 1 {
                _ = reader.readBits(count: 8) // colour_primaries
                _ = reader.readBits(count: 8) // transfer_characteristics
                _ = reader.readBits(count: 8) // matrix_coefficients
                if reader.failed { return nil }
            }
        }

        let chromaLocPresent = reader.readBit()
        if reader.failed { return nil }
        if chromaLocPresent == 1 {
            _ = reader.readUE()
            _ = reader.readUE()
            if reader.failed { return nil }
        }

        let timingInfoPresent = reader.readBit()
        if reader.failed { return nil }
        if timingInfoPresent == 0 { return nil }

        let numUnitsInTick = reader.readBits(count: 32)
        let timeScale = reader.readBits(count: 32)
        _ = reader.readBit() // fixed_frame_rate_flag
        if reader.failed { return nil }
        if numUnitsInTick == 0 { return nil }

        return Double(timeScale) / (Double(numUnitsInTick) * 2.0)
    }
}