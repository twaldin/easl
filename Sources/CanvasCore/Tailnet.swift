import Foundation

/// A machine on the user's tailnet, from `tailscale status --json`.
public struct TailnetPeer: Equatable, Sendable {
    /// The machine's name (`HostName`), as the user knows it. Display only: Tailscale says it is
    /// neither a DNS name nor unique, so a renamed machine's or a namesake's doesn't resolve to it.
    public var name: String
    /// What ssh connects to: the peer's `DNSName` (its fully qualified MagicDNS name), else its
    /// first Tailscale address.
    public var sshTarget: String
    /// `Peer[…].OS`: `macOS`, `linux`, `iOS`, `windows`, …
    public var os: String
    public var online: Bool

    public init(name: String, sshTarget: String, os: String, online: Bool) {
        self.name = name
        self.sshTarget = sshTarget
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
    /// A peer with neither a `DNSName` nor a Tailscale address can't be connected to, so it isn't one.
    public static func peers(status: Data) throws -> [TailnetPeer] {
        let json = try JSONDecoder().decode(JSONValue.self, from: status)
        let peers = json["Peer"]?.object?.values.compactMap { peer -> TailnetPeer? in
            guard let name = peer["HostName"]?.string, !name.isEmpty, let target = sshTarget(of: peer) else { return nil }
            return TailnetPeer(name: name, sshTarget: target, os: peer["OS"]?.string ?? "", online: peer["Online"]?.bool ?? false)
        } ?? []
        return peers.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.sshTarget < $1.sshTarget : order == .orderedAscending
        }
    }

    /// `DNSName` without its trailing dot ("studio.tail1234.ts.net." is how Tailscale writes it),
    /// else the first of `TailscaleIPs`.
    static func sshTarget(of peer: JSONValue) -> String? {
        var dns = peer["DNSName"]?.string ?? ""
        while dns.hasSuffix(".") { dns.removeLast() }
        if !dns.isEmpty { return dns }
        return peer["TailscaleIPs"]?.array?.first?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The tailnet's peers now; `unavailable` without tailscale, or when it isn't running.
    /// Cancelling the task ends `tailscale` and throws `CancellationError`.
    public static func peers() async throws -> [TailnetPeer] {
        guard let binary = binary() else {
            throw EaslConnection.Failure("unavailable", "tailscale isn't installed (looked in /Applications/Tailscale.app and on PATH)")
        }
        let result = try await RemoteHost.run(binary, ["status", "--json"], timeout: 10)
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
