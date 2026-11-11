import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Attention pills: bubbles beside marked objects and edge pills for offscreen ones never cover
/// each other, stay between the toolbar and the tray, sit outside their object where there's
/// room, never on its header, and cover other tiles only when they must.
struct PillLayoutTests {
    /// A 1400×900 window whose toolbar and tray leave y 72…842 clear.
    let clear = CGRect(x: 0, y: 72, width: 1400, height: 770)
    let bubble = CGSize(width: 300, height: 28)

    func marker(_ id: String, _ target: CGRect, width: CGFloat = 300, header: CGFloat = 26) -> PillLayout.Marker {
        .init(id: id, target: target, ringInset: 10, size: CGSize(width: width, height: 28), header: header)
    }

    func assertApart(_ rects: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(!a.intersects(b), "\(a) covers \(b)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func aBubbleSitsAboveItsObjectWhenThatCoversNothing() {
        let tile = CGRect(x: 200, y: 300, width: 640, height: 400)
        let placed = PillLayout.place(markers: [marker("a", tile)], edges: [], tiles: [.init(id: "a", rect: tile)], clear: clear)
        #expect(placed.bubbles["a"] == CGRect(x: 190, y: 256, width: 300, height: 28), "above the ring, left-aligned with it")
    }

    @Test func aBubbleGoesBesideItsObjectRatherThanCoverTheTileAboveIt() {
        // Zoomed out: two tiles stacked 12 pt apart on screen; a bubble above the lower one would
        // sit on the upper one's last rows.
        let upper = CGRect(x: 200, y: 100, width: 400, height: 300)
        let lower = CGRect(x: 200, y: 412, width: 400, height: 300)
        let placed = PillLayout.place(markers: [marker("lower", lower, header: 9)], edges: [], tiles: [.init(id: "upper", rect: upper), .init(id: "lower", rect: lower)], clear: clear)
        #expect(placed.bubbles["lower"] == CGRect(x: 616, y: 402, width: 300, height: 28), "right of the ring, level with its top")
    }

    @Test func aBubbleNeverCoversItsTilesTitleOrAddressBar() {
        // A browser tile at the top of the view (title bar and address bar
        // 58 pt), reaching under the tray, with a terminal beside it. No room above, left, or
        // below; right of it is the terminal.
        let browser = CGRect(x: 60, y: 90, width: 420, height: 800)
        let terminal = CGRect(x: 500, y: 90, width: 850, height: 560)
        let header = CGRect(x: browser.minX, y: browser.minY, width: browser.width, height: 58)
        let placed = PillLayout.place(markers: [marker("b", browser, header: 58)], edges: [], tiles: [.init(id: "b", rect: browser), .init(id: "t", rect: terminal)], clear: clear)
        let rect = try! #require(placed.bubbles["b"])
        #expect(!rect.intersects(header), "\(rect) covers the tile's controls")
        #expect(clear.contains(rect))

        let alone = PillLayout.place(markers: [marker("b", browser, header: 58)], edges: [], tiles: [.init(id: "b", rect: browser)], clear: clear)
        #expect(alone.bubbles["b"] == CGRect(x: 496, y: 80, width: 300, height: 28), "with room beside it, outside the tile")
    }

    @Test func bubblesOfNeighbouringObjectsNeverOverlap() {
        // Shot 15 of the omp study: two marked tiles side by side at fit zoom, long messages.
        let left = CGRect(x: 400, y: 400, width: 380, height: 260)
        let right = CGRect(x: 800, y: 400, width: 300, height: 260)
        let below = CGRect(x: 400, y: 680, width: 380, height: 150)
        let markers = [marker("left", left, width: 480), marker("right", right, width: 480), marker("below", below, width: 480)]
        let tiles = [("left", left), ("right", right), ("below", below)].map { PillLayout.Tile(id: $0.0, rect: $0.1) }
        let placed = PillLayout.place(markers: markers, edges: [], tiles: tiles, clear: clear)
        #expect(placed.bubbles.count == 3)
        assertApart(Array(placed.bubbles.values))
        for rect in placed.bubbles.values { #expect(clear.contains(rect)) }
    }

    @Test func pillsStayBetweenTheToolbarAndTheTray() {
        // A marked tile whose top is under the toolbar, one reaching under the tray.
        let high = CGRect(x: 100, y: 20, width: 500, height: 300)
        let low = CGRect(x: 700, y: 700, width: 500, height: 400)
        let placed = PillLayout.place(markers: [marker("high", high), marker("low", low)], edges: [.init(id: "off", target: CGPoint(x: 700, y: 3000), size: CGSize(width: 200, height: 32))],
                                      tiles: [.init(id: "high", rect: high), .init(id: "low", rect: low)], clear: clear)
        for rect in Array(placed.bubbles.values) + Array(placed.edges.values) { #expect(clear.contains(rect), "\(rect) is under the chrome") }
        #expect(placed.edges["off"]?.maxY == clear.maxY, "an object below the view: its pill on the bottom edge")
    }

    @Test func edgePillsSlideAlongTheirEdgeOffEachOtherAndOffBubbles() {
        // Three objects far to the right at nearly the same height, and a marked tile whose
        // bubble (y 436…464) sits on the right edge where their pills would go.
        let tile = CGRect(x: 1050, y: 480, width: 330, height: 200)
        let edges = (0..<3).map { PillLayout.Edge(id: "e\($0)", target: CGPoint(x: 5000, y: 440 + CGFloat($0) * 4), size: CGSize(width: 220, height: 32)) }
        let placed = PillLayout.place(markers: [marker("m", tile, width: 300)], edges: edges, tiles: [.init(id: "m", rect: tile)], clear: clear)
        let all = Array(placed.bubbles.values) + Array(placed.edges.values)
        #expect(all.count == 4)
        assertApart(all)
        for id in ["e0", "e1", "e2"] {
            let rect = try! #require(placed.edges[id])
            #expect(rect.maxX == clear.maxX - PillLayout.edgeMargin, "\(id) stays on the right edge")
        }
    }

    @Test func aBubbleGoesBelowItsObjectWhenAboveAndBesideAreTaken() {
        // Zoomed to ~48%: a terminal just above the marked tile and a neighbour 10 pt to its
        // right; a marked note far right leaves free room beside its bubble that the first
        // tile's bubble must not jump to.
        let terminal = CGRect(x: 100, y: 137, width: 475, height: 295)
        let tile = CGRect(x: 100, y: 470, width: 304, height: 212)
        let neighbour = CGRect(x: 414, y: 470, width: 238, height: 212)
        let note = CGRect(x: 1002, y: 327, width: 133, height: 43)
        let tiles = [("t", terminal), ("tile", tile), ("n", neighbour), ("note", note)].map { PillLayout.Tile(id: $0.0, rect: $0.1) }
        let placed = PillLayout.place(markers: [marker("tile", tile, width: 324, header: 12), marker("note", note, width: 160)], edges: [], tiles: tiles, clear: clear)
        #expect(placed.bubbles["tile"] == CGRect(x: 90, y: 698, width: 324, height: 28), "below the ring, left-aligned with it")
    }

    @Test func outsidePillsAvoidInlineBubblesAndBlockedPrompts() throws {
        let terminal = CGRect(x: 330, y: 100, width: 400, height: 400)
        let note = CGRect(x: 100, y: 512, width: 133, height: 43)
        let neighbour = CGRect(x: 240, y: 512, width: 460, height: 300)
        let ring = terminal.insetBy(dx: -10, dy: -10)
        let inline = CGRect(x: 400, y: 515, width: 160, height: 28)
        let tiles = [("terminal", terminal), ("note", note), ("neighbour", neighbour)].map {
            PillLayout.Tile(id: $0.0, rect: $0.1, header: 34)
        }
        let placed = PillLayout.place(markers: [marker("note", note, header: 34)],
                                      edges: [.init(id: "off", target: CGPoint(x: 700, y: -3000), size: CGSize(width: 200, height: 28))],
                                      tiles: tiles, occupied: [inline, ring], clear: clear)
        let bubble = try #require(placed.bubbles["note"])
        let edge = try #require(placed.edges["off"])
        for rect in [bubble, edge] {
            #expect(!rect.intersects(ring))
            #expect(!rect.intersects(inline))
            #expect(clear.contains(rect))
        }
        assertApart([bubble, edge, inline])
    }

    @Test func noBubbleCoversABlockedTerminalButItsOwn() {
        // Shot 15 of the codex2 study: a marked note below a blocked terminal's bottom-left corner,
        // a neighbour right of the note. Above the note, its bubble would hide 60 pt of the
        // terminal's last row (the approval prompt); on the note's title bar, much of the neighbour.
        let terminal = CGRect(x: 330, y: 100, width: 400, height: 400)
        let note = CGRect(x: 100, y: 512, width: 133, height: 43)
        let neighbour = CGRect(x: 240, y: 512, width: 460, height: 300)
        let tiles = [("t", terminal), ("note", note), ("n", neighbour)].map { PillLayout.Tile(id: $0.0, rect: $0.1) }
        let noteMarker = marker("note", note, width: 300, header: 12)

        var blocked = marker("t", terminal, width: 240)
        blocked.blocked = true
        let placed = PillLayout.place(markers: [noteMarker, blocked], edges: [], tiles: tiles, clear: clear)
        let bubble = try! #require(placed.bubbles["note"])
        let prompt = try! #require(placed.blocked["t"])
        #expect(!bubble.intersects(terminal.insetBy(dx: -10, dy: -10)), "\(bubble) covers the blocked terminal or its ring")
        #expect(placed.bubbles["t"] == nil && placed.blocked["note"] == nil)
        assertApart([bubble, prompt])
        #expect(clear.contains(prompt))
    }

    @Test func anEdgePillSlidesAlongItsEdgeOffABlockedTerminal() {
        // A blocked terminal reaching past the bottom of the view, and a marked note below it
        // offscreen: the note's pill belongs on the bottom edge, where it would sit on the terminal.
        let terminal = CGRect(x: 490, y: 400, width: 1000, height: 620)
        var blocked = marker("t", terminal, width: 240)
        blocked.blocked = true
        let placed = PillLayout.place(markers: [blocked], edges: [.init(id: "note", target: CGPoint(x: 720, y: 2000), size: CGSize(width: 200, height: 32))],
                                      tiles: [.init(id: "t", rect: terminal)], clear: clear)
        let pill = try! #require(placed.edges["note"])
        #expect(pill.maxY == clear.maxY, "still on the bottom edge")
        #expect(!pill.intersects(terminal.insetBy(dx: -10, dy: -10)), "\(pill) covers the blocked terminal")
    }

    @Test func aLongMessageTruncatesToTheObjectsWidth() {
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 300) == 300)
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 60) == PillLayout.minBubbleWidth, "a tiny object still gets a readable bubble")
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 2000) == PillLayout.maxBubbleWidth)
        #expect(PillLayout.bubbleWidth(natural: 120, ringWidth: 2000) == 120, "a short message keeps its own width")
    }

    @Test func aBubbleSlidesAlongASideRatherThanCoverATilesTitleBar() {
        // Warp study 4 / JetBrains 6: every side of the marked tile has a neighbour. Above, the
        // bubble would hide the upper tile's last rows; right of the ring, level with its top,
        // the right-hand tile's title bar; below, the lower tile's. Slid up along the right side
        // it covers nothing.
        let tile = CGRect(x: 300, y: 300, width: 500, height: 300)
        let above = CGRect(x: 300, y: 100, width: 500, height: 190)
        let right = CGRect(x: 826, y: 300, width: 500, height: 400)
        let below = CGRect(x: 300, y: 630, width: 500, height: 200)
        let left = CGRect(x: 0, y: 290, width: 280, height: 400)
        let tiles = [("m", tile), ("above", above), ("right", right), ("below", below), ("left", left)].map { PillLayout.Tile(id: $0.0, rect: $0.1, header: 26) }
        let placed = PillLayout.place(markers: [marker("m", tile)], edges: [], tiles: tiles, clear: clear)
        let rect = try! #require(placed.bubbles["m"])
        for other in tiles where other.id != "m" { #expect(!rect.intersects(other.rect), "\(rect) covers \(other.id)") }
        #expect(rect.insetBy(dx: -40, dy: -40).intersects(tile.insetBy(dx: -10, dy: -10)), "\(rect) strays from its tile")
    }

    @Test func noBubbleCoversTheTileWithTheKeyboard() {
        // A marked note in the view's top-left corner, a wide terminal beside it (20 pt away)
        // and a tile below it: every full-width spot beside the note hides some of the terminal.
        // Cut short, the bubble fits between the view's edge and the terminal; while the user
        // types in the terminal it never goes on it either.
        let note = CGRect(x: 20, y: 120, width: 200, height: 60)
        let terminal = CGRect(x: 240, y: 72, width: 760, height: 770)
        let below = CGRect(x: 20, y: 200, width: 200, height: 642)
        let tiles = [PillLayout.Tile(id: "note", rect: note, header: 12), .init(id: "t", rect: terminal, header: 26), .init(id: "b", rect: below, header: 26)]
        let noteMarker = marker("note", note, width: 300, header: 12)
        for focused in [nil, "t"] {
            let placed = PillLayout.place(markers: [noteMarker], edges: [], tiles: tiles, focused: focused, clear: clear)
            let bubble = try! #require(placed.bubbles["note"])
            #expect(!bubble.intersects(terminal), "\(bubble) covers the terminal (focused: \(focused ?? "none"))")
            #expect(!bubble.intersects(below), "\(bubble) covers the tile below")
            #expect(clear.contains(bubble))
        }
    }

    @Test func aBubbleCutsItselfShortRatherThanCoverANeighboursText() {
        // Incident study F6: centered on the Hypotheses note at 100%, the marked log note is
        // partly past the view's right edge, another note above it. Every full-width spot beside
        // the log's ring runs onto Hypotheses (clamped into the view) or the note above; the
        // bubble went across the end of a Hypotheses paragraph.
        let hypotheses = CGRect(x: 380, y: 250, width: 805, height: 505)
        let log = CGRect(x: 1310, y: 390, width: 400, height: 240)
        let above = CGRect(x: 1310, y: 40, width: 400, height: 330)
        let tiles = [("h", hypotheses), ("log", log), ("above", above)].map { PillLayout.Tile(id: $0.0, rect: $0.1, header: 26) }
        let placed = PillLayout.place(markers: [marker("log", log, width: 420)], edges: [], tiles: tiles, clear: clear)
        let bubble = try! #require(placed.bubbles["log"])
        #expect(!bubble.intersects(hypotheses) && !bubble.intersects(above), "\(bubble) covers a neighbour")
        #expect(clear.contains(bubble))
        #expect(bubble.width >= PillLayout.shortestBubble && bubble.width < 420, "\(bubble) is not cut to the room beside the ring")
        #expect(abs(bubble.minY - (log.maxY + 10 + PillLayout.spacing)) < 1, "\(bubble) is not against the ring's bottom")
    }

    @Test func aBlockedBubbleStaysNearItsRingWhenEveryNearbySpotCoversATile() {
        // Issue #3 (persona study X11): at fit zoom a blocked terminal sits in a packed grid of
        // small tiles, so every spot within `maxStray` of its ring covers a neighbour. The bubble
        // went to the empty band above the grid, 320 pt away, beside unrelated tiles.
        var tiles: [PillLayout.Tile] = []
        for row in 0..<10 {
            for column in 0..<12 {
                let rect = CGRect(x: 488 + CGFloat(column) * 101, y: 184 + CGFloat(row) * 81, width: 95, height: 75)
                if clear.intersects(rect) { tiles.append(.init(id: "\(row)-\(column)", rect: rect, header: 9)) }
            }
        }
        let terminal = try! #require(tiles.first { $0.id == "4-6" })
        let blocked = PillLayout.Marker(id: terminal.id, target: terminal.rect, ringInset: 10, size: CGSize(width: 378, height: 28), header: 9, blocked: true)
        let rect = try! #require(PillLayout.place(markers: [blocked], edges: [], tiles: tiles, clear: clear).blocked[terminal.id])
        let ring = terminal.rect.insetBy(dx: -10, dy: -10)
        let gap = hypot(max(0, ring.minX - rect.maxX, rect.minX - ring.maxX), max(0, ring.minY - rect.maxY, rect.minY - ring.maxY))
        #expect(gap <= PillLayout.maxStray, "\(rect) is \(Int(gap)) pt from its ring")
        #expect(!rect.intersects(terminal.rect.divided(atDistance: 9, from: .minYEdge).slice), "\(rect) covers the terminal's title bar")
        #expect(clear.contains(rect))
    }

    @Test func anEdgePillNeverCoversTheLineBeingTyped() {
        // Warp study 4: a focused shell fills the left of the view, its prompt on the row at
        // y 800…820; the marked object offscreen to the left is level with that row.
        let terminal = CGRect(x: 0, y: 72, width: 900, height: 770)
        let caret = CGRect(x: 0, y: 800, width: 900, height: 20)
        let placed = PillLayout.place(markers: [], edges: [.init(id: "off", target: CGPoint(x: -3000, y: 810), size: CGSize(width: 150, height: 24))],
                                      tiles: [.init(id: "t", rect: terminal, header: 26)], focused: "t", caret: caret, clear: clear)
        let pill = try! #require(placed.edges["off"])
        #expect(pill.minX == clear.minX + PillLayout.edgeMargin, "still on the left edge")
        #expect(!pill.intersects(caret), "\(pill) covers the prompt")
    }

    @Test func anEdgePillSlidesOffATilesTitleBar() {
        // A code tile reaching past the right edge, its title bar where the pill for
        // an object far right would sit.
        let tile = CGRect(x: 1000, y: 440, width: 600, height: 300)
        let titleBar = CGRect(x: 1000, y: 440, width: 600, height: 26)
        let placed = PillLayout.place(markers: [], edges: [.init(id: "off", target: CGPoint(x: 5000, y: 440), size: CGSize(width: 150, height: 24))],
                                      tiles: [.init(id: "code", rect: tile, header: 26)], clear: clear)
        let pill = try! #require(placed.edges["off"])
        #expect(pill.maxX == clear.maxX - PillLayout.edgeMargin, "still on the right edge")
        #expect(!pill.intersects(titleBar), "\(pill) covers the title bar")
        #expect(abs(pill.midY - 454) < 60, "\(pill) strays from where its object is")
    }

    @Test func anEdgePillSlidesToAStretchOfItsEdgeWithNothingUnderIt() {
        // Presenter P9: the follow tile fills the right edge from y 180 to 640; the pill for the
        // walkthrough off to the right sat on its code rows 11–12.
        let follow = CGRect(x: 1080, y: 180, width: 400, height: 460)
        let placed = PillLayout.place(markers: [], edges: [.init(id: "start", target: CGPoint(x: 4000, y: 480), size: CGSize(width: 150, height: 24))],
                                      tiles: [.init(id: "follow", rect: follow, header: 26)], clear: clear)
        let pill = try! #require(placed.edges["start"])
        #expect(pill.maxX == clear.maxX - PillLayout.edgeMargin, "still on the right edge")
        #expect(!pill.intersects(follow), "\(pill) covers the follow tile")
        #expect(clear.contains(pill))
    }

    @Test func anEdgePillFindsTheGapBetweenTilesAlongTheBottom() {
        // Confirm5 R2: the pill for a note below the view sat on the changes tile's Stage and
        // Discard buttons; a terminal and the changes tile fill the bottom edge but for a gap.
        let terminal = CGRect(x: 0, y: 400, width: 700, height: 600)
        let changes = CGRect(x: 740, y: 300, width: 700, height: 700)
        let placed = PillLayout.place(markers: [], edges: [.init(id: "note", target: CGPoint(x: 900, y: 3000), size: CGSize(width: 28, height: 24))],
                                      tiles: [.init(id: "t", rect: terminal, header: 26), .init(id: "c", rect: changes, header: 26)], clear: clear)
        let pill = try! #require(placed.edges["note"])
        #expect(pill.maxY > clear.maxY - PillLayout.edgeMargin, "\(pill) left the bottom edge")
        #expect(pill.minX >= terminal.maxX && pill.maxX <= changes.minX, "\(pill) is not in the gap")
    }

    @Test func anEdgePillWithNoClearStretchGoesToTheChromeBand() {
        // A terminal filling the right edge of the view: the pill becomes a chip in the toolbar
        // row, right of the toolbar, rather than sit on the terminal's text.
        let terminal = CGRect(x: 700, y: 60, width: 800, height: 900)
        let bands = [CGRect(x: 16, y: 20, width: 460, height: 34), CGRect(x: 924, y: 20, width: 460, height: 34)]
        let edge = PillLayout.Edge(id: "off", target: CGPoint(x: 5000, y: 500), size: CGSize(width: 150, height: 24))
        let placed = PillLayout.place(markers: [], edges: [edge], tiles: [.init(id: "t", rect: terminal, header: 26)], clear: clear, bands: bands)
        let chip = try! #require(placed.edges["off"])
        #expect(bands[1].contains(chip), "\(chip) is not in the band nearest its object")

        let two = PillLayout.place(markers: [], edges: [edge, .init(id: "off2", target: CGPoint(x: 5000, y: 520), size: CGSize(width: 150, height: 24))],
                                   tiles: [.init(id: "t", rect: terminal, header: 26)], clear: clear, bands: bands)
        assertApart(Array(two.edges.values))

        let without = PillLayout.place(markers: [], edges: [edge], tiles: [.init(id: "t", rect: terminal, header: 26)], clear: clear)
        #expect(try! #require(without.edges["off"]).maxX == clear.maxX - PillLayout.edgeMargin, "no band: on the edge as before")
    }
}
