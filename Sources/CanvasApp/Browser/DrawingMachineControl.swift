import AppKit
import CanvasCore

@MainActor
final class DrawingMachineControl: NSPopUpButton {
    var onChoose: ((DrawingMachine) -> Void)?
    private var current: DrawingMachine?
    private var machines: [DrawingMachine]?
    private var canSwitch = false

    init() {
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        bezelStyle = .inline
        font = ChromeText.font(.systemFont(ofSize: 11))
        target = self
        action = #selector(choseMachine)
        setAccessibilityLabel("Browser drawing machine")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var fittedWidth: CGFloat { min(160, max(64, fittingSize.width)) }

    func show(_ machine: DrawingMachine?) {
        current = machine
        rebuild()
    }

    func choices(_ machines: [DrawingMachine]?, canSwitch: Bool) {
        self.machines = machines
        self.canSwitch = canSwitch
        rebuild()
    }

    func applyScale() {
        font = ChromeText.font(.systemFont(ofSize: 11))
    }

    private func rebuild() {
        removeAllItems()
        let label: String
        if let current {
            let host = current.host.isEmpty ? current.id : current.host
            let offline = canSwitch && machines?.contains(where: { $0.id == current.id }) == false
            label = "Draws on \(host)\(offline ? " (offline)" : "")"
        } else {
            label = "No drawing Mac"
        }
        addItem(withTitle: label)
        guard let menu else { return }
        menu.addItem(.separator())
        if canSwitch {
            for machine in machines ?? [] {
                let host = machine.host.isEmpty ? machine.id : machine.host
                let duplicate = machines?.contains { $0.id != machine.id && $0.host == machine.host } == true
                let title = duplicate ? "\(host) · \(machine.id.suffix(6))" : host
                let item = NSMenuItem(title: title, action: #selector(choseMachine), keyEquivalent: "")
                item.target = self
                item.representedObject = machine
                item.state = machine.id == current?.id ? .on : .off
                item.isEnabled = machine.id != current?.id
                menu.addItem(item)
            }
            if machines?.isEmpty != false {
                let item = NSMenuItem(title: "No attached drawing Macs", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let warning = NSMenuItem(title: "Reloads in that Mac's own profile. Logins are not copied.", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            toolTip = "Choose the Mac that runs this page. Moving reloads its current URL in that Mac's own profile, without copying cookies or logins."
        } else {
            let item = NSMenuItem(title: "This board draws on its Mac host", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            toolTip = "This board's browser pages run on its Mac host."
        }
        menu.autoenablesItems = false
    }

    @objc private func choseMachine(_ sender: Any?) {
        let item = sender as? NSMenuItem ?? selectedItem
        guard let machine = item?.representedObject as? DrawingMachine, machine.id != current?.id else { return }
        selectItem(at: 0)
        onChoose?(machine)
    }
}
