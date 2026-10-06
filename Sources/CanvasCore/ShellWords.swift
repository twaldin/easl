/// POSIX shell words: what a terminal tile hands Ghostty (a command string, not argv) and ssh
/// (one remote command line).
public enum ShellWords {
    /// `argv` as single-quoted words, joined by spaces.
    public static func quote(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
    }
}
