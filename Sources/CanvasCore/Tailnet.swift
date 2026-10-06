import Foundation

/// A machine on the user's tailnet, from `tailscale status --json`.
public struct TailnetPeer: Equatable, Sendable {
    /// The machine's name (`HostName`), which MagicDNS and ssh resolve.
    public var name: String
    /// `Peer[…].OS`: `macOS`, `linux`, `iOS`, `windows`, …
    public var os: String
    public var online: Bool

    public init(name: String, os: String, online: Bool) {
        self.name = name
        self.os = os
        self.online = online
    }

    public var isMac: Bool { os == "macOS" }
}

/// The tailnet's machines, which File › Open Remote… offers as hosts.
public enum Tailnet {
    /// The tailscale CLI: the Mac app's own binary, else the one on PATH, else Homebrew's (an
    /// app launched from Finder has launchd's PATH, without Homebrew's directories).
    public static func binary(path: String? = ProcessInfo.processInfo.environment["PATH"],
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/tailscale" }
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"] + onPath + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        return candidates.first(where: isExecutable)
    }

    /// The peers in `tailscale status --json`'s output (this machine, `Self`, isn't one), by name.
    public static func peers(status: Data) throws -> [TailnetPeer] {
        let json = try JSONDecoder().decode(JSONValue.self, from: status)
        let peers = json["Peer"]?.object?.values.compactMap { peer -> TailnetPeer? in
            guard let name = peer["HostName"]?.string, !name.isEmpty else { return nil }
            return TailnetPeer(name: name, os: peer["OS"]?.string ?? "", online: peer["Online"]?.bool ?? false)
        } ?? []
        return peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The tailnet's peers now; `unavailable` without tailscale, or when it isn't running.
    public static func peers() async throws -> [TailnetPeer] {
        guard let binary = binary() else {
            throw EaslConnection.Failure("unavailable", "tailscale isn't installed (looked in /Applications/Tailscale.app and on PATH)")
        }
        let result = await RemoteHost.run(binary, ["status", "--json"], timeout: 10)
        guard result.status == 0 else {
            throw EaslConnection.Failure("unavailable", RemoteHost.lastLine(result.errors) ?? "tailscale status exited with status \(result.status)")
        }
        do {
            return try peers(status: Data(result.output.utf8))
        } catch {
            throw EaslConnection.Failure("unavailable", "tailscale status --json didn't answer JSON")
        }
    }
}
