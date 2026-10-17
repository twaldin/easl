import AppKit
import CanvasCore
import ObjectiveC

@MainActor
private final class Registration {
    weak var owner: AnyObject?
    let tag: NSView.ToolTipTag
    let rect: NSRect

    init(owner: AnyObject, tag: NSView.ToolTipTag, rect: NSRect) {
        self.owner = owner
        self.tag = tag
        self.rect = rect
    }
}

@MainActor
private enum TooltipProbe {
    static var registrations: [ObjectIdentifier: [Registration]] = [:]
    static var removals = 0

    static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let first = class_getInstanceMethod(NSView.self, original),
              let second = class_getInstanceMethod(NSView.self, replacement) else {
            fatalError("Cannot intercept AppKit tooltip methods")
        }
        method_exchangeImplementations(first, second)
    }

    static func install() {
        exchange(#selector(NSView.addToolTip(_:owner:userData:)), #selector(NSView.lifetimeAddToolTip(_:owner:userData:)))
        exchange(#selector(NSView.removeAllToolTips), #selector(NSView.lifetimeRemoveAllToolTips))
        exchange(#selector(NSView.removeToolTip(_:)), #selector(NSView.lifetimeRemoveToolTip(_:)))
    }

    static func registration(for view: NSView) -> Registration {
        let entries = registrations[ObjectIdentifier(view)] ?? []
        require(entries.count == 1, "Expected one author tooltip, got \(entries.count)")
        return entries[0]
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            exit(1)
        }
    }

    static func check(_ view: GroupView, expected: String, stage: String) {
        let registration = registration(for: view)
        guard let owner = registration.owner as? NSObject else {
            require(false, "\(stage) installed tooltip tag \(registration.tag) has a dead owner after autoreleasepool drain")
            return
        }
        let selector = NSSelectorFromString("view:stringForToolTip:point:userData:")
        let result: String?
        if owner.responds(to: selector) {
            typealias Callback = @convention(c) (AnyObject, Selector, NSView, NSView.ToolTipTag, NSPoint, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
            let callback = unsafeBitCast(owner.method(for: selector), to: Callback.self)
            let point = NSPoint(x: registration.rect.midX, y: registration.rect.midY)
            result = callback(owner, selector, view, registration.tag, point, nil)?.takeUnretainedValue() as? String
        } else {
            result = owner.description
        }
        require(result == expected, "\(stage) expected \(expected.debugDescription), got \(String(describing: result))")
        print("PASS \(stage) tag=\(registration.tag) owner=\(type(of: owner)) text=\(expected)")
    }
}

extension NSView {
    @objc fileprivate func lifetimeAddToolTip(_ rect: NSRect, owner: AnyObject, userData: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        let tag = lifetimeAddToolTip(rect, owner: owner, userData: userData)
        if self is GroupView {
            TooltipProbe.registrations[ObjectIdentifier(self), default: []].append(Registration(owner: owner, tag: tag, rect: rect))
        }
        return tag
    }

    @objc fileprivate func lifetimeRemoveAllToolTips() {
        if self is GroupView {
            TooltipProbe.registrations[ObjectIdentifier(self)] = []
            TooltipProbe.removals += 1
        }
        lifetimeRemoveAllToolTips()
    }

    @objc fileprivate func lifetimeRemoveToolTip(_ tag: NSView.ToolTipTag) {
        if self is GroupView {
            TooltipProbe.registrations[ObjectIdentifier(self)]?.removeAll { $0.tag == tag }
            TooltipProbe.removals += 1
        }
        lifetimeRemoveToolTip(tag)
    }
}

@main
private enum TooltipLifetime {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        TooltipProbe.install()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let object = CanvasObject(id: "tooltip-group", type: .group, frame: Frame(x: 0, y: 0, w: 900, h: 300), z: 0, createdBy: .user, createdAt: Date(), props: .object(["members": .array([]), "title": .string("Regression")]))
        guard let group = GroupView(object: object), let content = window.contentView else {
            fatalError("Cannot create real group view and window")
        }
        content.addSubview(group)
        autoreleasepool {
            group.show(region: NSRect(x: 0, y: 0, width: 900, height: 300))
            group.author = "Lifetime regression author with a deliberately long dynamic name 0123456789"
        }
        TooltipProbe.check(group, expected: "Created by the terminal “Lifetime regression author with a deliberately long dynamic name 0123456789”", stage: "initial registration")
        autoreleasepool { group.author = "Replacement author with another deliberately long dynamic name 9876543210" }
        TooltipProbe.check(group, expected: "Created by the terminal “Replacement author with another deliberately long dynamic name 9876543210”", stage: "author replacement")
        autoreleasepool { group.show(region: NSRect(x: 0, y: 0, width: 800, height: 300)) }
        TooltipProbe.check(group, expected: "Created by the terminal “Replacement author with another deliberately long dynamic name 9876543210”", stage: "resize")
        let removalsBeforeDetach = TooltipProbe.removals
        autoreleasepool { group.removeFromSuperview() }
        TooltipProbe.require(group.window == nil, "Detached group still has a window")
        print("OBSERVE detach intercepted-removals=\(TooltipProbe.removals - removalsBeforeDetach) captured-tags=\(TooltipProbe.registrations[ObjectIdentifier(group)]?.count ?? 0). Captured tags do not prove AppKit internal registration state.")
        autoreleasepool {
            content.addSubview(group)
            group.author = "Reattached author with a deliberately long dynamic name 1357924680"
        }
        TooltipProbe.require(group.window === window, "Reattached group has the wrong window")
        TooltipProbe.check(group, expected: "Created by the terminal “Reattached author with a deliberately long dynamic name 1357924680”", stage: "reattach and refresh")
        autoreleasepool { group.author = nil }
        TooltipProbe.require(TooltipProbe.registrations[ObjectIdentifier(group)]?.isEmpty == true, "Removing author leaves a captured tooltip registration")
        autoreleasepool {
            group.author = "Restored author with a deliberately long dynamic name 2468013579"
            group.show(region: NSRect(x: 0, y: 0, width: 20, height: 300))
        }
        TooltipProbe.require(TooltipProbe.registrations[ObjectIdentifier(group)]?.isEmpty == true, "Narrow group keeps an author tooltip after the mark disappears")
        autoreleasepool { group.show(region: NSRect(x: 0, y: 0, width: 900, height: 300)) }
        TooltipProbe.check(group, expected: "Created by the terminal “Restored author with a deliberately long dynamic name 2468013579”", stage: "mark restored")
        withExtendedLifetime((window, group)) {}
        window.close()
        print("PASS GroupView tooltip lifetime regression")
    }
}
