/// Build and query an IDR (key-frame) index over an H.264 Annex-B NAL stream.
///
/// vea v0.10's chapter-driven focused-revisit path repeatedly seeks to target
/// timestamps in the same .h264 file. Re-parsing + re-decoding from byte 0 on
/// every visit is wasteful; probe emits this index once and decode reuses it
/// via `--seek-to-ts <seconds>` (with `--probe-meta` to avoid re-scanning;
/// without `--probe-meta`, decode falls back to building the index in-process).
///
/// Frame-counting assumption: only nal_unit_type 1 (non-IDR slice) and 5 (IDR
/// slice) increment `frameIndex`. NAL types 2-4 (slice data partitions) and
/// 19/20 (auxiliary/extension slices) are not counted; streams using them
/// will produce off-by-N frame indices and need a separate code path.
import Foundation

public struct IDREntry: Equatable {
    /// 0-based position among I/P frame NAL units (type 1 or 5). SPS/PPS/SEI
    /// and other non-frame NALs are not counted, so this aligns with decoded
    /// frame order.
    public let frameIndex: Int
    /// Index of this IDR inside the original `nalUnits` array returned by
    /// `H264Stream.parse`. The decode loop iterates from this offset.
    public let nalUnitOffset: Int
    /// Estimated presentation timestamp in seconds, computed as
    /// `frameIndex / fps`. P1.2 SPSParser will plug in real fps; until then
    /// callers pass the demo's 30 fps assumption. Probe writes this value
    /// using fps=30 (no SPS parser yet) — treat probe output as advisory and
    /// have decode recompute with its own --fps option.
    public let estimatedTs: Double

    public init(frameIndex: Int, nalUnitOffset: Int, estimatedTs: Double) {
        self.frameIndex = frameIndex
        self.nalUnitOffset = nalUnitOffset
        self.estimatedTs = estimatedTs
    }
}

public enum IDRIndex {

    /// Walk the parsed NAL units once and record every IDR (nal_unit_type=5).
    /// Non-frame NAL units are skipped for `frameIndex` counting so the
    /// produced entries align with decoded frame order.
    public static func build(
        nalUnits: [(payload: Data, nalUnitType: UInt8)],
        fps: Double = 30.0
    ) -> [IDREntry] {
        var entries: [IDREntry] = []
        var frameCounter = 0
        let frameDuration = fps > 0 ? 1.0 / fps : 0.0
        for (offset, unit) in nalUnits.enumerated() {
            switch unit.nalUnitType {
            case 5:
                entries.append(IDREntry(
                    frameIndex: frameCounter,
                    nalUnitOffset: offset,
                    estimatedTs: Double(frameCounter) * frameDuration
                ))
                frameCounter += 1
            case 1:
                frameCounter += 1
            default:
                continue
            }
        }
        return entries
    }

    /// Reconstruct an index from probe.jsonl's `idr_index` array. Each element
    /// is expected to have keys `frame_idx`, `nalu_offset`, `ts`. Returns
    /// `nil` if the structure is malformed; callers should fall back to
    /// `build`. `estimatedTs` is recomputed with `fps` because probe writes
    /// it using fps=30.
    public static func fromProbeMeta(_ raw: [[String: Any]], fps: Double) -> [IDREntry]? {
        var out: [IDREntry] = []
        out.reserveCapacity(raw.count)
        let frameDuration = fps > 0 ? 1.0 / fps : 0.0
        for item in raw {
            guard
                let frameIdx = item["frame_idx"] as? Int,
                let naluOffset = item["nalu_offset"] as? Int
            else { return nil }
            let ts = Double(frameIdx) * frameDuration
            out.append(IDREntry(frameIndex: frameIdx, nalUnitOffset: naluOffset, estimatedTs: ts))
        }
        return out
    }

    /// Return the IDR with the largest `estimatedTs` that is still ≤ `ts`.
    /// Entries from `build` are stored in NAL-stream order, so their
    /// `estimatedTs` is monotonically non-decreasing — a linear scan with an
    /// early break is sufficient. Returns `nil` when the index is empty or
    /// every IDR is in the future; callers should fall back to decoding from
    /// the start of the file.
    public static func nearestIDR(at ts: Double, in index: [IDREntry]) -> IDREntry? {
        var best: IDREntry?
        for entry in index {
            if entry.estimatedTs <= ts {
                best = entry
            } else {
                break
            }
        }
        return best
    }
}
