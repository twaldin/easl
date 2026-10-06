// Extracts the glyph table easld approximates text with when no Mac client measures it
// (docs/design/next.md, "The client protocol"): for every face the app sets text in, the advance
// of each code point in `codePoints` (with CoreText's font fallback), a default advance for the
// rest, and the line height TextKit gives a line of it. No font data beyond those numbers.
//
//   swift scripts/glyph-widths.swift > easld/internal/measure/glyphs/glyphs.json
//
// The faces follow NoteRenderer (notes), CodeCaption (code captions) and DrawingStyle (text
// shapes, shape and arrow labels); keep them in step with those and with easld's
// internal/measure/glyphs, which names faces the same way.
import AppKit
import CoreText

/// Code points with an advance of their own: ASCII, Latin-1, Latin Extended-A, general
/// punctuation, and the symbols the app draws.
let codePoints: [ClosedRange<UInt32>] = [
    0x20...0x7E, 0xA0...0x17F, 0x2010...0x2027, 0x2030...0x2030, 0x2032...0x2033, 0x2039...0x203A,
    0x20AC...0x20AC, 0x2122...0x2122, 0x2190...0x2195, 0x21A9...0x21A9, 0x21E7...0x21E7, 0x2212...0x2212,
    0x2260...0x2260, 0x2264...0x2265, 0x2303...0x2303, 0x2318...0x2318, 0x2325...0x2325,
    0x2610...0x2611, 0x26A0...0x26A0, 0x2713...0x2713, 0x2717...0x2717,
]

/// NoteRenderer.font(_:adding:).
func adding(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
    NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
}

func sizeKey(_ size: CGFloat) -> String {
    String(format: "%g", (Double(size) * 100).rounded() / 100)
}

var faces: [(key: String, font: NSFont)] = []

// Notes (NoteRenderer): the body at 13 pt and headings at 20, 17, 15 and 13 pt (bold to h2,
// semibold below), each with emphasis (italic) and strong (bold) added; fence captions at 10.5
// pt medium (a stale one's warning bold); code captions (CodeCaption) at 11.5 pt.
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold]
for (size, weight) in [(13.0, "regular"), (13.0, "semibold"), (15.0, "semibold"), (17.0, "bold"), (20.0, "bold")] {
    let base = NSFont.systemFont(ofSize: size, weight: weights[weight]!)
    let key = "system-\(sizeKey(size))-\(weight)"
    faces.append((key, base))
    faces.append((key + "-italic", adding(base, .italic)))
    if weight != "bold" {
        faces.append((key + "-bold", adding(base, .bold)))
        faces.append((key + "-bold-italic", adding(adding(base, .bold), .italic)))
    }
}
faces.append(("system-10.5-medium", NSFont.systemFont(ofSize: 10.5, weight: .medium)))
faces.append(("system-10.5-bold", NSFont.systemFont(ofSize: 10.5, weight: .bold)))
faces.append(("system-11.5-regular", NSFont.systemFont(ofSize: 11.5)))
// Code: code in captions at 11 pt, fence rows at 11.5 pt, inline code at 0.9 of its text's size.
for size in [11, 11.5, 13 * 0.9, 15 * 0.9, 17 * 0.9, 20 * 0.9] as [CGFloat] {
    faces.append(("mono-\(sizeKey(size))", NSFont.monospacedSystemFont(ofSize: size, weight: .regular)))
}
// The drawing layer (DrawingStyle): Shantell Sans, the bundled variable font's first face, at
// the arrow label, shape label and text sizes.
let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("resources/fonts/ShantellSans-Variable.ttf")
var registerError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registerError),
      let shantell = (CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor])?.first else {
    FileHandle.standardError.write("glyph-widths: cannot load \(fontURL.path)\n".data(using: .utf8)!)
    exit(1)
}
for size in [15, 18, 20] as [CGFloat] {
    faces.append(("shantell-\(sizeKey(size))", NSFont(descriptor: shantell as NSFontDescriptor, size: size)!))
}

/// Width CoreText sets `text` at in `font`, falling back to other fonts for missing glyphs as
/// AppKit's text layout does.
func width(_ text: String, _ font: NSFont) -> CGFloat {
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil)
}

/// Height TextKit 2 gives one line of `font` (ObjectMeasure.noteTextHeight's layout, line height
/// multiple 1): what notes and NSAttributedString.boundingRect stack lines by.
func lineHeight(_ font: NSFont) -> CGFloat {
    let content = NSTextContentStorage()
    let layout = NSTextLayoutManager()
    content.addTextLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 10_000, height: 0))
    layout.textContainer = container
    content.attributedString = NSAttributedString(string: "Hg", attributes: [.font: font])
    layout.ensureLayout(for: layout.documentRange)
    return layout.usageBoundsForTextContainer.height
}

func hundredths(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }

var out = "{\n"
out += "  \"about\": \"Advances (hundredths of a point) and line heights (points) of the faces easl sets text in, for easld's approximation when no Mac client measures text. Generated by swift scripts/glyph-widths.swift; do not edit.\",\n"
out += "  \"macOS\": \"\(ProcessInfo.processInfo.operatingSystemVersionString)\",\n"
out += "  \"codePoints\": [\(codePoints.map { "[\($0.lowerBound), \($0.upperBound)]" }.joined(separator: ", "))],\n"
out += "  \"faces\": {\n"
var written: [(key: String, advances: [Int])] = []
for (index, face) in faces.enumerated() {
    let font = face.font
    var advances: [Int] = []
    for range in codePoints {
        for value in range {
            advances.append(hundredths(width(String(Character(Unicode.Scalar(value)!)), font)))
        }
    }
    // Characters outside the table: the mean lowercase advance (East Asian wide characters and
    // emoji take 1 em, which easld derives from the size).
    let lowercase = (0x61...0x7A).map { width(String(Character(Unicode.Scalar(UInt32($0))!)), font) }
    let fallback = lowercase.reduce(0, +) / CGFloat(lowercase.count)
    var fields = [
        "\"font\": \"\(font.fontName)\"",
        "\"size\": \(sizeKey(font.pointSize))",
        "\"lineHeight\": \(String(format: "%g", Double(lineHeight(font))))",
        "\"ascent\": \(String(format: "%.2f", Double(font.ascender)))",
        "\"descent\": \(String(format: "%.2f", Double(-font.descender)))",
        "\"fallback\": \(hundredths(fallback))",
    ]
    // Kept small: a face whose advances repeat an earlier face's names it; a face where most
    // code points share one advance (monospaced) lists only the others.
    var counts: [Int: Int] = [:]
    for advance in advances { counts[advance, default: 0] += 1 }
    let common = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!
    if let same = written.first(where: { $0.advances == advances }) {
        fields.append("\"advancesOf\": \"\(same.key)\"")
    } else if common.value * 2 > advances.count {
        var flat: [UInt32] = []
        for range in codePoints { flat.append(contentsOf: range) }
        let others = zip(flat, advances).filter { $0.1 != common.key }.map { "\"\($0.0)\": \($0.1)" }
        fields.append("\"advance\": \(common.key)")
        fields.append("\"except\": {\(others.joined(separator: ", "))}")
    } else {
        fields.append("\"advances\": [\(advances.map(String.init).joined(separator: ","))]")
    }
    written.append((face.key, advances))
    out += "    \"\(face.key)\": {\(fields.joined(separator: ", "))}\(index == faces.count - 1 ? "" : ",")\n"
}
out += "  }\n}\n"
print(out, terminator: "")
