/// Read the first line of a JSONL file and parse it as a JSON object.
/// Used by `decode --probe-meta <path>` to reuse an index emitted by `probe`.
import Foundation

enum JSONLReader {

    enum Error: Swift.Error {
        case fileUnreadable(String)
        case emptyFile
        case notAnObject
    }

    /// Open `path`, read the first non-empty line, return it parsed as a
    /// `[String: Any]`. Throws on IO / JSON / shape errors.
    static func readFirstLine(at path: String) throws -> [String: Any] {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Error.fileUnreadable(path)
        }
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            let parsed = try JSONSerialization.jsonObject(with: lineData)
            guard let dict = parsed as? [String: Any] else {
                throw Error.notAnObject
            }
            return dict
        }
        throw Error.emptyFile
    }
}
