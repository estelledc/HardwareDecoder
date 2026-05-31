/// `hardware-decoder probe` — inspect an H.264 Annex-B file's SPS without
/// decoding any frames. Outputs a single JSON object on stdout suitable for
/// use as a cache key or pipeline metadata header.
import Foundation
import ArgumentParser
import CryptoKit
import HardwareDecoderCore

struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Print stream metadata as a single-line JSON object on stdout."
    )

    @Option(name: .long, help: "Path to a raw H.264 Annex-B bitstream file.")
    var input: String

    func run() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input) else {
            FileHandle.standardError.write(Data("ERROR: input file not found: \(input)\n".utf8))
            ProbeCommand.exit(withError: ExitCode(2))
        }

        guard let videoData = readH264File(path: input) else {
            FileHandle.standardError.write(Data("ERROR: failed to read \(input)\n".utf8))
            ProbeCommand.exit(withError: ExitCode(2))
        }

        let nalUnits = H264Stream.parse(videoData)
        if nalUnits.isEmpty {
            FileHandle.standardError.write(Data("ERROR: no valid NAL units found\n".utf8))
            ProbeCommand.exit(withError: ExitCode(3))
        }

        let (spsRaw, ppsRaw) = H264Stream.extractSPSPPS(from: nalUnits)
        guard let sps = spsRaw, let pps = ppsRaw else {
            FileHandle.standardError.write(Data("ERROR: SPS or PPS not found\n".utf8))
            ProbeCommand.exit(withError: ExitCode(3))
        }

        let frameNalCount = nalUnits.filter { $0.nalUnitType == 1 || $0.nalUnitType == 5 }.count

        // Stable stream identifier for cache keys: sha256 of the raw SPS+PPS
        // payloads. Two files re-encoded from the same source still hit
        // different keys (different motion vectors), but the same file with
        // identical parameter sets hits the same key.
        var hasher = SHA256()
        hasher.update(data: sps)
        hasher.update(data: pps)
        let streamID = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined().prefix(16)

        // Parse SPS for real metadata. Falls back to raw byte reads when
        // bitstream parsing fails (truncated SPS, unsupported syntax, etc.)
        let spsInfo = H264SPSParser.parse(sps)
        let profileIdc = spsInfo?.profileIdc ?? (sps.count > 1 ? Int(sps[1]) : -1)
        let levelIdc = spsInfo?.levelIdc ?? (sps.count > 3 ? Int(sps[3]) : -1)
        let fpsHint = spsInfo?.fpsHint
        // Prefer SPS-parsed fps for the IDR index ts column. Fallback 30.
        let indexFps = fpsHint ?? 30.0

        let idrEntries = IDRIndex.build(nalUnits: nalUnits, fps: indexFps)
        let estimatedDuration: Double? = (frameNalCount > 0 && fpsHint != nil)
            ? Double(frameNalCount) / fpsHint!
            : nil

        var output: [String: Any] = [
            "stream_id": String(streamID),
            "profile_idc": profileIdc,
            "level_idc": levelIdc,
            "frame_count_estimate": frameNalCount,
            "estimated_duration_s": estimatedDuration as Any? ?? NSNull(),
            "fps_hint": fpsHint as Any? ?? NSNull(),
            "idr_index": idrEntries.map {
                ["frame_idx": $0.frameIndex, "nalu_offset": $0.nalUnitOffset, "ts": $0.estimatedTs]
            },
        ]

        if let info = spsInfo {
            output["width"] = info.width
            output["height"] = info.height
            output["chroma_format_idc"] = info.chromaFormatIdc
            output["num_ref_frames"] = info.numRefFrames
            output["has_b_frames_hint"] = info.hasBFramesHint
        } else {
            output["width"] = NSNull()
            output["height"] = NSNull()
            output["_sps_parse_failed"] = true
        }

        JSONLWriter.write(output)
    }
}
