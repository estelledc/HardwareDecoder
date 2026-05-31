/// `hardware-decoder decode` — H.264 Annex-B file → JPG/PNG sequence.
import Foundation
import ArgumentParser
import VideoToolbox
import CoreMedia
import HardwareDecoderCore

struct DecodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Decode an H.264 Annex-B bitstream into a sequence of image files."
    )

    @Option(name: .long, help: "Path to a raw H.264 Annex-B bitstream file.")
    var input: String

    @Option(name: .long, help: "Directory where decoded frames are written. Created if missing.")
    var outputDir: String

    @Option(name: .long, help: "Output image format (jpg or png).")
    var format: String = "jpg"

    @Option(name: .long, help: "JPEG quality, 0-100. Ignored when format=png.")
    var quality: Int = 70

    @Option(name: .long, help: "Maximum output height in pixels. 0 = preserve original.")
    var maxHeight: Int = 480

    @Option(name: .long, help: "Optional start time in seconds (inclusive).")
    var tsStart: Double?

    @Option(name: .long, help: "Optional end time in seconds (inclusive).")
    var tsEnd: Double?

    @Option(name: .long, help: "Optional target frames-per-second (downsample). Default: emit every decoded I/P frame.")
    var fps: Double?

    @Option(name: .long, help: "printf pattern for frame filenames (extension is appended automatically).")
    var filenamePattern: String = "f_%05d"

    @Option(name: .long, help: "Seek to the nearest IDR <= this timestamp before decoding (seconds).")
    var seekToTs: Double?

    @Option(name: .long, help: "Path to probe.jsonl; reuses its idr_index instead of rebuilding in-process.")
    var probeMeta: String?

    @Flag(name: .long, help: "Print verbose debug information to stderr.")
    var verbose: Bool = false

    func run() throws {
        coreVerbose = verbose

        // 1. Validate input
        let fm = FileManager.default
        guard fm.fileExists(atPath: input) else {
            FileHandle.standardError.write(Data("ERROR: input file not found: \(input)\n".utf8))
            DecodeCommand.exit(withError: ExitCode(2))
        }

        guard let frameFormat = FrameFormat(rawValue: format.lowercased()) else {
            FileHandle.standardError.write(Data("ERROR: unsupported format '\(format)'. Use jpg, png, or raw.\n".utf8))
            DecodeCommand.exit(withError: ExitCode(EXIT_FAILURE))
        }

        if frameFormat.isRaw && verbose {
            FileHandle.standardError.write(Data("INFO: format=raw — streaming BGRA8 bytes to stdout; --output-dir is ignored\n".utf8))
        }

        let saver = FrameSaver(
            outputDir: frameFormat.isRaw ? nil : URL(fileURLWithPath: outputDir),
            format: frameFormat,
            quality: max(0, min(100, Double(quality))) / 100.0,
            maxHeight: max(0, maxHeight),
            filenamePattern: filenamePattern
        )

        // 2. Read & parse NAL stream
        guard let videoData = readH264File(path: input) else {
            FileHandle.standardError.write(Data("ERROR: failed to read \(input)\n".utf8))
            DecodeCommand.exit(withError: ExitCode(2))
        }

        let nalUnits = H264Stream.parse(videoData)
        if verbose {
            FileHandle.standardError.write(Data("INFO: parsed \(nalUnits.count) NAL units\n".utf8))
        }
        if nalUnits.isEmpty {
            FileHandle.standardError.write(Data("ERROR: no valid NAL units found\n".utf8))
            DecodeCommand.exit(withError: ExitCode(3))
        }

        let (sps, pps) = H264Stream.extractSPSPPS(from: nalUnits)
        guard let sps = sps, let pps = pps else {
            FileHandle.standardError.write(Data("ERROR: SPS or PPS not found in stream\n".utf8))
            DecodeCommand.exit(withError: ExitCode(3))
        }
        // Derive source fps from SPS, falling back to 30 (the demo's assumption).
        let spsInfo = H264SPSParser.parse(sps)
        if verbose, let info = spsInfo {
            FileHandle.standardError.write(Data("INFO: SPS width=\(info.width) height=\(info.height) fps=\(info.fpsHint.map { String(format: "%.3f", $0) } ?? "n/a")\n".utf8))
        }

        // 3. Wire up decoder
        let decoder = H264Decoder(config: .init(
            requireHardware: false,
            idrSessionRebuild: true,
            enableEmergencyRecovery: true
        ))

        var frameCounter = 0
        var lastEmittedTs: Double = -.infinity
        var earlyTermination = false

        let tsStartCopy = tsStart
        let tsEndCopy = tsEnd
        let fpsCopy = fps

        let resolvedMaxHeight = max(0, maxHeight)

        decoder.onFrame = { imageBuffer, pts in
            let ts = CMTimeGetSeconds(pts)
            if let s = tsStartCopy, ts < s { return }
            if let e = tsEndCopy, ts > e {
                earlyTermination = true
                return
            }
            if let f = fpsCopy, f > 0 {
                let interval = 1.0 / f
                if ts - lastEmittedTs < interval { return }
                lastEmittedTs = ts
            }

            do {
                if frameFormat.isRaw {
                    // Compute output dims here so meta.size_bytes and
                    // saveAsRaw produce byte-exact output. Caller is the
                    // single source of truth for downscale math.
                    let srcW = CVPixelBufferGetWidth(imageBuffer)
                    let srcH = CVPixelBufferGetHeight(imageBuffer)
                    var outW = srcW
                    var outH = srcH
                    if resolvedMaxHeight > 0 && srcH > resolvedMaxHeight {
                        let scale = Double(resolvedMaxHeight) / Double(srcH)
                        outW = max(1, Int((Double(srcW) * scale).rounded()))
                        outH = resolvedMaxHeight
                    }
                    let sizeBytes = outW * outH * 4

                    JSONLWriter.write([
                        "ts": ts,
                        "frame_idx": frameCounter,
                        "width": outW,
                        "height": outH,
                        "size_bytes": sizeBytes,
                        "format": "bgra8",
                    ])
                    fflush(stdout)

                    let bytesWritten = try saver.saveAsRaw(
                        imageBuffer: imageBuffer,
                        outWidth: outW,
                        outHeight: outH
                    )
                    if bytesWritten != sizeBytes {
                        FileHandle.standardError.write(Data("WARN: raw frame size mismatch (got \(bytesWritten) expected \(sizeBytes))\n".utf8))
                    }
                    frameCounter += 1
                } else {
                    let outputPath = try saver.save(imageBuffer: imageBuffer, frameIndex: frameCounter)
                    JSONLWriter.write([
                        "ts": ts,
                        "frame_idx": frameCounter,
                        "width": CVPixelBufferGetWidth(imageBuffer),
                        "height": CVPixelBufferGetHeight(imageBuffer),
                        "path": outputPath.path,
                    ])
                    frameCounter += 1
                }
            } catch {
                FileHandle.standardError.write(Data("WARN: frame save failed at ts=\(ts): \(error)\n".utf8))
            }
        }

        do {
            try decoder.loadParameterSets(sps: sps, pps: pps)
        } catch H264Decoder.DecodeError.formatDescriptionFailed(let s) {
            FileHandle.standardError.write(Data("ERROR: failed to create video format description (\(s))\n".utf8))
            DecodeCommand.exit(withError: ExitCode(3))
        } catch H264Decoder.DecodeError.sessionCreationFailed(let s) {
            FileHandle.standardError.write(Data("ERROR: failed to create VTDecompressionSession (\(s))\n".utf8))
            DecodeCommand.exit(withError: ExitCode(4))
        } catch {
            FileHandle.standardError.write(Data("ERROR: decoder setup failed: \(error)\n".utf8))
            DecodeCommand.exit(withError: ExitCode(EXIT_FAILURE))
        }

        // 4. Decode loop with optional seek-to-IDR
        var ptsValue: Int64 = 0
        var startOffset = 0
        // Source video fps from SPS for ts↔frame_idx math. Falls back to 30
        // when SPS lacks VUI timing info. Note: this is the SOURCE fps, not
        // the --fps downsample.
        let sourceFps = spsInfo?.fpsHint ?? 30.0
        if let seek = seekToTs {
            // Prefer probe-emitted index; fall back to in-process build.
            var idrIndex: [IDREntry]? = nil
            if let metaPath = probeMeta {
                if let raw = try? JSONLReader.readFirstLine(at: metaPath),
                   let arr = raw["idr_index"] as? [[String: Any]] {
                    idrIndex = IDRIndex.fromProbeMeta(arr, fps: sourceFps)
                } else if verbose {
                    FileHandle.standardError.write(Data("WARN: --probe-meta unreadable, rebuilding in-process\n".utf8))
                }
            }
            let index = idrIndex ?? IDRIndex.build(nalUnits: nalUnits, fps: sourceFps)
            if let target = IDRIndex.nearestIDR(at: seek, in: index) {
                startOffset = target.nalUnitOffset
                // PTS comes from the actual IDR's estimatedTs (frame_idx/fps),
                // not the user-supplied seek input which is approximate.
                ptsValue = Int64(target.estimatedTs * sourceFps)
                if verbose {
                    FileHandle.standardError.write(Data("INFO: seek ts=\(seek)s -> IDR frame_idx=\(target.frameIndex) ts=\(target.estimatedTs)s nalu_offset=\(target.nalUnitOffset)\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("WARN: no IDR <= ts=\(seek)s, decoding from start\n".utf8))
            }
        }

        for (idx, (payload, nalType)) in nalUnits.enumerated() {
            if idx < startOffset { continue }
            if earlyTermination { break }
            guard nalType == 1 || nalType == 5 else { continue }

            if verbose {
                FileHandle.standardError.write(Data("INFO: NAL[\(idx + 1)] type=\(nalType == 5 ? "IDR" : "P") size=\(payload.count)B\n".utf8))
            }

            // Use sourceFps as timescale so PTS values agree with the SPS-
            // derived frame rate. Int32 cast clamps if SPS reports an
            // unusually high fps (>2^31 fps would already be nonsense).
            let ts = CMTime(value: ptsValue, timescale: Int32(max(1.0, sourceFps).rounded()))
            do {
                try decoder.feed(naluData: payload, timestamp: ts)
            } catch H264Decoder.DecodeError.decodeFailed(let s) {
                if verbose {
                    FileHandle.standardError.write(Data("WARN: decode failed (\(s)) on NAL[\(idx + 1)]\n".utf8))
                }
                // Don't exit — continue decoding subsequent frames.
            } catch {
                FileHandle.standardError.write(Data("ERROR: unrecoverable decode error: \(error)\n".utf8))
                DecodeCommand.exit(withError: ExitCode(5))
            }
            usleep(20000) // Preserves the demo's "extreme reliability" pacing.
            ptsValue += 1
        }

        decoder.waitForCompletion()
        usleep(1_000_000) // Give async callbacks time to drain.
        decoder.invalidate()

        if verbose {
            FileHandle.standardError.write(Data("INFO: emitted \(frameCounter) frames\n".utf8))
        }
    }
}
