/// Persist a decoded `CVImageBuffer` as a JPG/PNG file under an output
/// directory, or stream raw BGRA8 pixel bytes to stdout. Caller computes
/// final width/height for raw mode and passes them in so meta and bytes
/// stay byte-exact consistent.
import Foundation
import CoreMedia
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers

enum FrameFormat: String {
    case jpg
    case png
    case raw

    /// Optional: file-backed formats only. `.raw` returns nil so any
    /// accidental call site fails loudly instead of producing an empty
    /// CFString that Core Graphics rejects with an opaque error.
    var utType: CFString? {
        switch self {
        case .jpg: return UTType.jpeg.identifier as CFString
        case .png: return UTType.png.identifier as CFString
        case .raw: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpg: return "jpg"
        case .png: return "png"
        case .raw: return "bgra"
        }
    }

    var isRaw: Bool { self == .raw }
}

struct FrameSaver {
    /// nil iff format == .raw. Enforced in initializer.
    let outputDir: URL?
    let format: FrameFormat
    let quality: Double          // 0.0-1.0, JPG only
    let maxHeight: Int           // 0 = preserve original (file-backed mode)
    let filenamePattern: String  // e.g. "f_%05d"

    // Reuse a single CIContext across frames to avoid Metal pipeline rebuild.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    init(outputDir: URL?, format: FrameFormat, quality: Double, maxHeight: Int, filenamePattern: String) {
        if format.isRaw {
            precondition(outputDir == nil, "raw format must not be given an outputDir")
        } else {
            precondition(outputDir != nil, "file-backed format requires outputDir")
        }
        self.outputDir = outputDir
        self.format = format
        self.quality = quality
        self.maxHeight = maxHeight
        self.filenamePattern = filenamePattern
    }

    /// File-backed save (JPG/PNG). Returns the absolute URL written.
    func save(imageBuffer: CVImageBuffer, frameIndex: Int) throws -> URL {
        guard let outputDir = outputDir else {
            throw SaveError.outputDirMissing
        }
        guard let utType = format.utType else {
            throw SaveError.unsupportedFileFormat
        }
        try ensureOutputDir(outputDir)

        var ciImage = CIImage(cvImageBuffer: imageBuffer)
        if maxHeight > 0 {
            let originalHeight = Double(CVPixelBufferGetHeight(imageBuffer))
            if originalHeight > Double(maxHeight) {
                let scale = Double(maxHeight) / originalHeight
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        let context = FrameSaver.sharedContext
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw SaveError.cgImageCreationFailed
        }

        let filename = String(format: "\(filenamePattern).\(format.fileExtension)", frameIndex)
        let outputURL = outputDir.appendingPathComponent(filename)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            utType,
            1,
            nil
        ) else {
            throw SaveError.destinationCreationFailed
        }

        var properties: [CFString: Any] = [:]
        if format == .jpg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw SaveError.finalizeFailed
        }

        return outputURL
    }

    /// Render the frame to BGRA8 at exactly `outWidth x outHeight` and
    /// write the raw bytes to stdout. The caller is responsible for:
    ///   1. emitting the JSONL meta line BEFORE calling this method,
    ///   2. flushing stdout between meta and bytes (see DecodeCommand).
    /// Returns bytes actually written so the caller can sanity-check
    /// against meta.size_bytes.
    func saveAsRaw(imageBuffer: CVImageBuffer, outWidth: Int, outHeight: Int) throws -> Int {
        guard outWidth > 0, outHeight > 0 else {
            throw SaveError.invalidExtent
        }

        var ciImage = CIImage(cvImageBuffer: imageBuffer)
        let srcExtent = ciImage.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else {
            throw SaveError.invalidExtent
        }

        // Scale to EXACT target dims. Use independent x/y scale so a
        // ±1px floor mismatch in the caller's math can never desync
        // bytesWritten from meta.size_bytes.
        let sx = CGFloat(outWidth) / srcExtent.width
        let sy = CGFloat(outHeight) / srcExtent.height
        if sx != 1 || sy != 1 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let bytesPerRow = outWidth * 4
        let totalBytes = bytesPerRow * outHeight
        let renderBounds = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Allocate, render, write — all inside withUnsafeMutableBytes so
        // the buffer lifetime spans the stdout.write call. Avoids the
        // Data(bytesNoCopy:) lifetime UB pattern.
        var pixels = [UInt8](repeating: 0, count: totalBytes)
        try pixels.withUnsafeMutableBytes { buf -> Void in
            guard let base = buf.baseAddress else {
                throw SaveError.bufferAllocFailed
            }
            // Translate so renderBounds origin maps to pixel (0,0).
            let translated = ciImage.transformed(by: CGAffineTransform(
                translationX: -ciImage.extent.origin.x,
                y: -ciImage.extent.origin.y
            ))
            FrameSaver.sharedContext.render(
                translated,
                toBitmap: base,
                rowBytes: bytesPerRow,
                bounds: renderBounds,
                format: .BGRA8,
                colorSpace: colorSpace
            )
            // Write directly from the live buffer; Data wraps without
            // copying for the duration of this scope.
            let data = Data(bytesNoCopy: base, count: totalBytes, deallocator: .none)
            FileHandle.standardOutput.write(data)
        }

        return totalBytes
    }

    private func ensureOutputDir(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    enum SaveError: Error {
        case cgImageCreationFailed
        case destinationCreationFailed
        case finalizeFailed
        case invalidExtent
        case bufferAllocFailed
        case outputDirMissing
        case unsupportedFileFormat
    }
}