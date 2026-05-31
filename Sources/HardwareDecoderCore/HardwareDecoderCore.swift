/// HardwareDecoder Core — H.264 hardware decoding primitives backed by VideoToolbox.
///
/// Public surface:
/// - `H264Stream`: pure NAL parsing helpers, no global state.
/// - `H264Decoder`: instance-based hardware decoder. One instance per video
///   stream, no shared state between instances.
/// - `readH264File(path:)`: convenience file reader.
/// - `coreLog(_:force:)` + `coreVerbose`: log control surface.
import Foundation

public enum HardwareDecoderCore {
    public static let version = "0.1.0"
}

/// Verbose flag — when `false` (default) Core suppresses chatty diagnostics
/// to stderr. CLI flips this on with `--verbose`. Errors and structural
/// failures are always written regardless.
public var coreVerbose: Bool = false

/// Single sink for all of Core's stderr output. Honours `coreVerbose` for
/// chatty messages; `force: true` overrides for genuine errors.
@inline(__always)
internal func coreLog(_ message: String, force: Bool = false) {
    if force || coreVerbose {
        FileHandle.standardError.write(Data(message.utf8))
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
