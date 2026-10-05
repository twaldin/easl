import Foundation

/// The file a browser tile's download is saved as: the name the server or page suggested, made
/// safe for one path component, and numbered the way Finder numbers a copy ("report 2.pdf")
/// when that name is taken, so a download never replaces a file already in the folder.
public enum DownloadName {
    /// `suggested` as a file name: no slashes or colons (path separators in POSIX and Finder),
    /// no control characters, no leading dots (a hidden file nobody finds), at most 255 UTF-8
    /// bytes keeping its extension; "download" when nothing is left.
    public static func sanitized(_ suggested: String) -> String {
        var name = String(suggested.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            if scalar.properties.generalCategory == .control { return " " }
            return Character(scalar)
        })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "download" }
        guard name.utf8.count > 255 else { return name }
        let (stem, ext) = split(name)
        var shortened = stem
        while shortened.utf8.count + ext.utf8.count > 255, !shortened.isEmpty { shortened.removeLast() }
        return shortened + ext
    }

    /// The first of `name`, "stem 2.ext", "stem 3.ext", … that `taken` says is free. `.tar.gz`
    /// and the like keep both extensions after the number.
    public static func unique(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let (stem, ext) = split(name)
        var number = 2
        while taken("\(stem) \(number)\(ext)") { number += 1 }
        return "\(stem) \(number)\(ext)"
    }

    /// "archive.tar.gz" → ("archive", ".tar.gz"); "notes.txt" → ("notes", ".txt"); "Makefile"
    /// → ("Makefile", "").
    static func split(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where lower.hasSuffix(double) && lower.count > double.count {
            return (String(name.dropLast(double.count)), String(name.suffix(double.count)))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
