import Foundation

/// The host-side storage protocol for images pasted into one terminal session.
public enum TerminalPaste {
    public static let keepDays = 7

    public static func stageArguments(instance: String, session: String, name: String, size: Int) -> [String] {
        ["stage", instance, session, name, String(size)]
    }

    public static func discardArguments(instance: String, session: String) -> [String] {
        ["discard", instance, session]
    }

    public static func text(paths: [String]) -> String {
        paths.map(RemoteHost.quote).joined(separator: " ")
    }

    public static func stagedPath(_ output: String) -> String? {
        let path = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), parts.count >= 5 else { return nil }
        let root = parts[parts.count - 4]
        guard root.hasPrefix("easl-paste-"), !root.dropFirst(11).isEmpty,
              root.dropFirst(11).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.suffix(3).allSatisfy({ !$0.hasPrefix(".") && $0.unicodeScalars.allSatisfy(safe.contains) }) else { return nil }
        return path
    }

    /// Session end is the primary cleanup. Pruning runs opportunistically after seven days.
    public static let script = #"""
        set -eu
        mode=${1:-} instance=${2:-} session=${3:-}
        fail() { printf '%s\n' "easl: $1" >&2; exit 2; }
        component() {
          case $1 in ''|.*|*[!A-Za-z0-9._-]*) fail 'invalid staging name' ;; esac
        }
        component "$instance"
        component "$session"
        case $mode in
          stage)
            [ "$#" = 5 ] || fail 'invalid stage arguments'
            name=$4 size=$5
            component "$name"
            case $size in ''|*[!0-9]*) fail 'invalid image size' ;; esac ;;
          discard) [ "$#" = 3 ] || fail 'invalid discard arguments' ;;
          *) fail 'invalid staging operation' ;;
        esac
        umask 077
        base=${TMPDIR:-/tmp}
        case $base in /*) ;; *) fail 'temporary directory is not absolute' ;; esac
        base=$(CDPATH= cd -P -- "$base" && pwd -P) || fail 'temporary directory is unavailable'
        uid=$(id -u)
        root="${base%/}/easl-paste-$uid"
        case $(uname -s) in Darwin) stat_owner() { stat -f '%u' "$1"; } ;; *) stat_owner() { stat -c '%u' "$1"; } ;; esac
        private_directory() {
          [ ! -L "$1" ] && [ -d "$1" ] && [ "$(stat_owner "$1")" = "$uid" ] || fail 'unsafe staging directory'
          chmod 700 "$1" || fail 'cannot protect staging directory'
        }
        if [ ! -e "$root" ] && [ ! -L "$root" ]; then
          [ "$mode" != discard ] || exit 0
          mkdir "$root" 2>/dev/null || [ -d "$root" ] || fail 'cannot create staging root'
        fi
        private_directory "$root"
        find "$root" -mindepth 3 -type f -mtime +\#(keepDays - 1) -exec rm -f {} + 2>/dev/null || :
        find "$root" -depth -mindepth 1 -type d -empty -mtime +\#(keepDays - 1) -exec rmdir {} + 2>/dev/null || :
        instance_dir="$root/$instance"
        dir="$instance_dir/$session"
        for folder in "$instance_dir" "$dir"; do
          if [ ! -e "$folder" ] && [ ! -L "$folder" ]; then
            [ "$mode" != discard ] || exit 0
            mkdir "$folder" 2>/dev/null || [ -d "$folder" ] || fail 'cannot create staging directory'
          fi
          private_directory "$folder"
        done
        if [ "$mode" = discard ]; then
          rm -rf -- "$dir"
          exit 0
        fi
        part=$(mktemp "$dir/.part.XXXXXX") || fail 'cannot create image file'
        trap 'rm -f -- "$part"' EXIT
        trap 'exit 1' HUP INT TERM
        cat > "$part" || fail 'image transfer failed'
        actual=$(wc -c < "$part" | tr -d '[:space:]')
        [ "$actual" = "$size" ] || fail 'image arrived incomplete'
        chmod 600 "$part" || fail 'cannot protect image file'
        dest="$dir/$name"
        [ ! -e "$dest" ] && [ ! -L "$dest" ] || fail 'image name already exists'
        ln "$part" "$dest" 2>/dev/null || fail 'image name already exists'
        rm -f -- "$part"
        trap - EXIT HUP INT TERM
        printf '%s\n' "$dest"
        """#
}
