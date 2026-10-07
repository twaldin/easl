// Replays input into an easl instance launched with EASL_DEV_INPUT=1 (see docs/testing.md).
// Coordinates are window-content points with a top-left origin, matching `view.snapshot` pixels / 2.
//
//   dev-input <pid> click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
//   dev-input <pid> rightclick <x> <y>
//   dev-input <pid> menu <x> <y> "<item>/<submenu item>"  perform a context-menu item without opening the menu
//   dev-input <pid> mainmenu "<menu>/<item>"          perform a menu-bar item (e.g. "Edit/Send Mentions To/codex")
//   dev-input <pid> drag <x> <y> <toX> <toY> [--mods …] [--hold]   --hold: no mouse-up (shoot mid-drag)
//   dev-input <pid> release <x> <y>                  the mouse-up ending a held drag
//   dev-input <pid> flags <x> <y> [--mods …]         hold modifiers with the pointer at x,y (hover); no --mods releases
//   dev-input <pid> move <x> <y>                     move the pointer (tracking-area hover, e.g. code navigation)
//   dev-input <pid> text "<string>"                  insert text into the first responder
//   dev-input <pid> command <selector>               e.g. insertNewline: deleteBackward: cancelOperation:
//   dev-input <pid> shortcut <char> [--mods cmd]     a key press by character, e.g. shortcut z --mods cmd, shortcut +
//   dev-input <pid> key <name> [--mods …]            a key press by name: return escape tab space delete forwarddelete
//                                                    up down left right home end pageup pagedown (or one character)
//   dev-input <pid> scroll <x> <y> <dx> <dy> [--lines]  pan by pixels (a trackpad's precise scroll);
//                                                    --lines: a mouse wheel's notches (dy 1 = one line up)
//   dev-input <pid> magnify <x> <y> <amount>         pinch at x,y: zoom × (1 + amount) per step (0.05 in, -0.05 out)
//   dev-input <pid> perf [ms]                        an idle DevPerf span (EASL_DEV_PERF=1), default 5000 ms
//   dev-input <pid> idle on|off|auto                 feed the user-idle policy terminals redraw by (5 redraws/s
//                                                    when idle) a minute idle / zero, or follow the Mac again
//   dev-input <pid> panel <path>                     choose <path> in the window's open panel (a page's file
//                                                    upload), which runs out of process where no click reaches
//   dev-input <pid> remote <ssh target> <board> [host home]  open another easl's board as a remote board (the
//                                                    host found over ssh; host home: its support directory)
//   any kind: --repeat N [--interval ms]             a burst (default 8 ms apart); app.log reports the longest gap
//   scroll --repeat N --gesture                      the burst as one phased trackpad gesture: began and ended
//                                                    without movement, the steps between as changed
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
let mods = option("--mods")
let clicks = option("--clicks")
let repeatCount = option("--repeat")
let interval = option("--interval")
let hold = args.contains("--hold")
args.removeAll { $0 == "--hold" }
let gesture = args.contains("--gesture")
args.removeAll { $0 == "--gesture" }
let lines = args.contains("--lines")
args.removeAll { $0 == "--lines" }
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: dev-input <pid> <kind> …  (see header of scripts/dev-input.swift)\n".utf8))
    exit(2)
}
var info: [String: String] = ["pid": args[0], "kind": args[1]]
let rest = Array(args.dropFirst(2))
switch args[1] {
case "click", "rightclick", "flags", "move", "release":
    guard rest.count >= 2 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]
case "menu":
    guard rest.count >= 3 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["path"] = rest.dropFirst(2).joined(separator: " ")
case "mainmenu":
    guard !rest.isEmpty else { exit(2) }
    info["path"] = rest.joined(separator: " ")
case "drag":
    guard rest.count >= 4 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["toX"] = rest[2]; info["toY"] = rest[3]
case "text":
    info["text"] = rest.joined(separator: " ")
case "command":
    info["selector"] = rest.first ?? ""
case "shortcut", "key":
    info["key"] = rest.first ?? ""
case "scroll":
    guard rest.count >= 4 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["dx"] = rest[2]; info["dy"] = rest[3]
case "magnify":
    guard rest.count >= 3 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["amount"] = rest[2]
case "perf":
    info["ms"] = rest.first ?? "5000"
case "idle":
    guard let state = rest.first, ["on", "off", "auto"].contains(state) else { exit(2) }
    info["state"] = state
case "panel":
    guard !rest.isEmpty else { exit(2) }
    info["path"] = rest.joined(separator: " ")
case "remote":
    guard rest.count >= 2 else { exit(2) }
    info["target"] = rest[0]; info["board"] = rest[1]
    if rest.count >= 3 { info["home"] = rest.dropFirst(2).joined(separator: " ") }
default:
    FileHandle.standardError.write(Data("unknown kind \(args[1])\n".utf8))
    exit(2)
}
if let mods { info["mods"] = mods }
if let clicks { info["clicks"] = clicks }
if hold { info["hold"] = "1" }
if let repeatCount { info["repeat"] = repeatCount }
if let interval { info["interval"] = interval }
if gesture { info["gesture"] = "1" }
if lines { info["lines"] = "1" }
DistributedNotificationCenter.default().postNotificationName(Notification.Name("canvas.dev.input"), object: nil, userInfo: info, deliverImmediately: true)
// Replayed events are queued; give the app a moment before the caller inspects state.
usleep(150_000)
