import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = BatteryMonitor()
    private let alerts = Alerts()

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let leftLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rightLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    private let lowBatteryItem = NSMenuItem(title: "Low Battery Alerts", action: #selector(toggleAlert), keyEquivalent: "")
    private let disconnectItem = NSMenuItem(title: "Disconnect Alerts", action: #selector(toggleAlert), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            // Template image, so macOS tints it for light and dark menu bars
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            icon?.accessibilityDescription = "TOTEM battery"
            button.image = icon
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        for item in [statusLine, leftLine, rightLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        lowBatteryItem.representedObject = Alerts.lowBatteryKey
        disconnectItem.representedObject = Alerts.disconnectKey
        for item in [lowBatteryItem, disconnectItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        monitor.onChange = { [weak self] in
            guard let self else { return }
            alerts.update(levels: monitor.levels, isConnected: monitor.isConnected)
            render()
        }
        render()
    }

    private func render() {
        let left = monitor.levels[.left].map(String.init) ?? "--"
        let right = monitor.levels[.right].map(String.init) ?? "--"

        // The half closer to empty decides the colour: an average would hide one dying half
        let lowest = [monitor.levels[.left], monitor.levels[.right]].compactMap { $0 }.min()
        if monitor.isConnected, let lowest {
            statusItem.button?.attributedTitle = NSAttributedString(string: " ●", attributes: [
                .foregroundColor: Self.statusColor(for: lowest),
                .font: NSFont.systemFont(ofSize: 9),
                .baselineOffset: 1,
            ])
        } else {
            statusItem.button?.title = ""
        }
        statusItem.button?.appearsDisabled = !monitor.isConnected
        statusItem.button?.toolTip = "TOTEM  Left \(left)%  Right \(right)%"

        statusLine.title = monitor.isConnected ? "TOTEM connected" : "TOTEM not connected"
        leftLine.title = "Left: \(left)%"
        // The left half reports no level for the right half while their link is down
        rightLine.title = monitor.isConnected && monitor.levels[.right] == nil ? "Right: not connected" : "Right: \(right)%"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in [lowBatteryItem, disconnectItem] {
            item.state = UserDefaults.standard.bool(forKey: item.representedObject as? String ?? "") ? .on : .off
        }
    }

    private static func statusColor(for percent: Int) -> NSColor {
        switch percent {
        case 50...: return .systemGreen
        case 20..<50: return .systemYellow
        default: return .systemRed
        }
    }

    @objc private func refresh() {
        monitor.refresh()
    }

    @objc private func toggleAlert(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        render()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        render()
    }
}
