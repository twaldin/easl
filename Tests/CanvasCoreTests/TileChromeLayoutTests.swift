import Foundation
import Testing
import CanvasCore
#if canImport(AppKit)
import AppKit
#endif

struct TileChromeLayoutTests {
    @Test func modeUsesOnlyChromeTextLevel() {
        #expect(TileChromeLayout.mode(scale: 1) == .twoTrack)
        #expect(TileChromeLayout.mode(scale: 1.15) == .twoTrack)
        #expect(TileChromeLayout.mode(scale: 1.3) == .folded)
        #expect(TileChromeLayout.mode(scale: 1.5) == .folded)
    }


    @Test(arguments: [1.3, 1.5])
    func foldedSlotsHaveOneRowAndNoAuthor(_ scale: Double) {
        for width: CGFloat in [160, 352, 800] {
            for trailing: CGFloat in [0, 84] {
                let frames = TileChromeLayout.frames(width: width, trailing: trailing, terminal: true, scale: scale, needsYouWidth: 160)
                #expect(frames.author == .zero)
                #expect(frames.type.maxX <= frames.title.minX)
                #expect(frames.title.maxX <= frames.state.minX)
                #expect(frames.state.maxX <= frames.typing.minX)
                #expect(frames.typing.maxX <= frames.needsYou.minX)
                #expect(abs(frames.title.midY - frames.state.midY) <= 0.5)
                #expect(abs(frames.title.midY - frames.typing.midY) <= 0.5)
                for slot in [frames.type, frames.title, frames.state, frames.typing, frames.needsYou] {
                    #expect(slot.minY >= 0)
                    #expect(slot.maxY <= RenderMath.tileTitleHeight)
                }
                #expect(frames.needsYou.maxX <= width - 32 - trailing)
            }
        }
    }

    @Test(arguments: [1.0, 1.15, 1.3, 1.5])
    func fullAuthorAndPathSurviveTheFold(_ scale: Double) {
        let name = "A deliberately long creation-time author name"
        let path = "/outside/the/board/source.swift"
        var object = CanvasObject(id: "authored", type: .code, frame: Frame(x: 0, y: 0, w: 352, h: 232), z: 0,
                                  createdBy: .agent(tile: "deleted"), createdAt: Date(), props: .object([:]))
        object.authorName = name
        let author = AuthorMark.name(of: object, in: [:]) { _ in "A renamed live terminal" }
        let tip = TileChromeLayout.titleToolTip(path: path, author: author, scale: scale)
        #expect(tip?.contains(path) == true)
        if scale >= 1.3 {
            #expect(tip?.contains(name) == true)
            #expect(TileChromeLayout.titleToolTip(path: nil, author: author, scale: scale)?.contains(name) == true)
        } else {
            #expect(tip == path)
            #expect(TileChromeLayout.titleToolTip(path: nil, author: name, scale: scale) == nil)
        }
    }
}

#if canImport(AppKit)
@MainActor
struct TileChromeInkTests {
    private final class FlippedView: NSView {
        nonisolated override var isFlipped: Bool { true }
    }

    private func ink(_ text: String, role: ChromeRole, frame: CGRect, scale: Double) throws -> Set<Int> {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 100,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.bitmapData)
        data.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let label = NSTextField(labelWithString: text)
        label.font = role.font(scale: scale)
        label.textColor = .black
        label.lineBreakMode = role == .title ? .byTruncatingMiddle : .byTruncatingTail
        if role == .author { label.alignment = .right }
        let host = FlippedView(frame: CGRect(x: 0, y: 0, width: 800, height: 50))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: 100)
        context.cgContext.scaleBy(x: 2, y: -2)
        label.cell?.draw(withFrame: frame, in: host)
        NSGraphicsContext.restoreGraphicsState()
        var result: Set<Int> = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] != 0 {
                result.insert(y * bitmap.pixelsWide + x)
            }
        }
        return result
    }
    @Test(arguments: [1.0, 1.15])
    func foldOnlyInputsDoNotMoveLowScaleText(_ scale: Double) throws {
        let reference = TileChromeLayout.frames(width: 352, trailing: 40, terminal: true, scale: scale)
        let withAttention = TileChromeLayout.frames(width: 352, trailing: 40, terminal: true, scale: scale,
                                                   state: false, typing: false, needsYouWidth: 160)
        for (text, role, before, after) in [
            ("AgjpQy title", ChromeRole.title, reference.title, withAttention.title),
            ("working", .state, reference.state, withAttention.state),
            ("typing", .typing, reference.typing, withAttention.typing),
            ("AgjpQy author", .author, reference.author, withAttention.author),
        ] {
            let baseline = try ink(text, role: role, frame: before, scale: scale)
            #expect(!baseline.isEmpty)
            #expect(try ink(text, role: role, frame: after, scale: scale) == baseline)
        }
    }


    @Test(arguments: [1.0, 1.15, 1.3, 1.5])
    func nativeDrawnInkNeverOverlaps(_ scale: Double) throws {
        for width: CGFloat in [352, 800] {
            for trailing: CGFloat in [0, 84] {
                let frames = TileChromeLayout.frames(width: width, trailing: trailing, terminal: true, scale: scale,
                                                      needsYouWidth: width == 800 ? 160 : 0)
                var labels: [(String, ChromeRole, CGRect)] = [
                    ("AgjpQy · a long title with descenders", .title, frames.title),
                    ("working", .state, frames.state), ("typing", .typing, frames.typing),
                ]
                if scale < 1.3 { labels.append(("AgjpQy author", .author, frames.author)) }
                var occupied: Set<Int> = []
                for (text, role, frame) in labels {
                    let pixels = try ink(text, role: role, frame: frame, scale: scale)
                    #expect(!pixels.isEmpty, "Native ink oracle must draw every label")
                    #expect(occupied.isDisjoint(with: pixels), "Drawn ink collides at \(scale), width \(width), trailing \(trailing), role \(role)")
                    occupied.formUnion(pixels)
                }
            }
        }
    }
}
#endif
