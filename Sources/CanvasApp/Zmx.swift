import CanvasCore
import Foundation

/// zmx, which keeps terminal tiles' sessions (`AppPaths.zmx`), or a host's zmx over ssh for a
/// hosted tile's (`HostRoute`, `HostedTerminal.zmx`). Every call blocks until zmx exits: call
/// them off the main actor.
enum Zmx {
    /// Runs zmx with `arguments`, here or on `host`, handing `consume` its output chunk by chunk
    /// while it writes (it blocks once the pipe buffer fills, so waiting first would deadlock).
    /// False when zmx is missing, doesn't start, or fails (on a host: or isn't reachable).
    @discardableResult
    static func run(_ arguments: [String], on host: HostRoute? = nil, _ consume: (Data) -> Void) -> Bool {
        let process = Process()
        if let host {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = host.ssh(HostedTerminal.zmx(arguments))
            process.standardInput = FileHandle.nullDevice
        } else {
            guard let zmx = AppPaths.zmx else { return false }
            process.executableURL = URL(fileURLWithPath: zmx)
            process.arguments = arguments
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let reader = output.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty { consume(chunk) }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `zmx list`: a line per running session, any instance's (`name=<session>\tpid=…\t…`, the
    /// current one marked `*`); nil when zmx is missing or fails.
    static func list() -> String? {
        var data = Data()
        guard run(["list"], { data.append($0) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
