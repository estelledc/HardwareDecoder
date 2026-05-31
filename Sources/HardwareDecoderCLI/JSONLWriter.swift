/// stdout JSONL writer — one JSON object per line, flushed eagerly so external
/// processes consuming the stream see frames as they arrive.
import Foundation

enum JSONLWriter {
    /// Emit a single JSON line to stdout. Keys are written in deterministic
    /// order so callers can rely on byte-stable output. Failure to encode a
    /// value is logged to stderr and the line is skipped.
    static func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object) else {
            FileHandle.standardError.write(Data("WARN: invalid JSON object skipped: \(object)\n".utf8))
            return
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            FileHandle.standardError.write(Data("WARN: JSON encoding failed: \(object)\n".utf8))
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
