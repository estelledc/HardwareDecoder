/// Pure helpers over an H.264 Annex-B bytestream — no global state, no
/// VideoToolbox dependency. These functions all work on raw `Data` slices
/// and are safe to call from concurrent contexts.
import Foundation

public enum H264Stream {

    /// Slice an Annex-B bytestream into NAL units. Both 3-byte (00 00 01) and
    /// 4-byte (00 00 00 01) start codes are recognised.
    public static func parse(_ data: Data) -> [(payload: Data, nalUnitType: UInt8)] {
        var units: [(Data, UInt8)] = []
        var i = 0
        while i < data.count - 3 {
            var startCodeLen = 0
            if i + 3 < data.count
                && data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x01 {
                startCodeLen = 3
            } else if i + 4 < data.count
                && data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                startCodeLen = 4
            }

            if startCodeLen > 0 {
                let nalStart = i + startCodeLen
                var next = nalStart
                var foundNextStart = false
                while next < data.count - 2 {
                    let isThree = data[next] == 0x00 && data[next + 1] == 0x00
                        && (next + 2 < data.count && data[next + 2] == 0x01)
                    let isFour = next + 3 < data.count
                        && data[next] == 0x00 && data[next + 1] == 0x00
                        && data[next + 2] == 0x00 && data[next + 3] == 0x01
                    if isThree || isFour {
                        foundNextStart = true
                        break
                    }
                    next += 1
                }
                // If we ran off the end without finding another start code,
                // the rest of the buffer is the final NAL payload.
                if !foundNextStart {
                    next = data.count
                }

                if nalStart < next && nalStart < data.count {
                    let nal = data.subdata(in: nalStart..<next)
                    if !nal.isEmpty {
                        let nalType = nal[0] & 0x1F
                        units.append((nal, nalType))
                    }
                }
                i = next
            } else {
                i += 1
            }
        }
        return units
    }

    /// Find the first SPS (type=7) and PPS (type=8) NAL units. Returns the
    /// raw payloads (no start code).
    public static func extractSPSPPS(
        from units: [(payload: Data, nalUnitType: UInt8)]
    ) -> (sps: Data?, pps: Data?) {
        var sps: Data?
        var pps: Data?
        for (payload, type) in units {
            if type == 7, sps == nil { sps = payload }
            if type == 8, pps == nil { pps = payload }
            if sps != nil && pps != nil { break }
        }
        return (sps, pps)
    }

    /// Strip a 3- or 4-byte start code prefix if present. Returns the input
    /// unchanged otherwise.
    public static func removeStartCode(from data: Data) -> Data {
        if data.count >= 4
            && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            return data.subdata(in: 4..<data.count)
        }
        if data.count >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    /// True iff the buffer starts with a 3- or 4-byte Annex-B start code.
    public static func hasStartCode(_ data: Data) -> Bool {
        if data.count >= 4
            && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            return true
        }
        if data.count >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
            return true
        }
        return false
    }

    /// Clear the `forbidden_zero_bit` (high bit of the NAL header byte).
    /// Some hardware capture chains leave this bit set on lossy streams; VT
    /// rejects the buffer when it is 1.
    public static func fixForbiddenBit(_ data: inout Data) {
        guard !data.isEmpty else { return }
        if (data[0] & 0x80) != 0 {
            data[0] = data[0] & 0x7F
        }
    }
}

/// Read an entire `.h264` file into memory. Returns `nil` and writes a
/// structural error to stderr on failure.
public func readH264File(path: String) -> Data? {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        coreLog("成功读取视频文件，大小: \(data.count) 字节")
        return data
    } catch {
        coreLog("读取文件失败: \(error.localizedDescription)", force: true)
        return nil
    }
}
