/// hardware-decoder CLI entry point — wires the `decode` and `probe`
/// subcommands and dispatches based on argv via swift-argument-parser.
import ArgumentParser

struct HardwareDecoderCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hardware-decoder",
        abstract: "macOS H.264 hardware decoding CLI backed by VideoToolbox.",
        version: "0.0.1",
        subcommands: [DecodeCommand.self, ProbeCommand.self]
    )
}

HardwareDecoderCLI.main()
