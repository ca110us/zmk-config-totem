import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = BatteryMonitor()

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let leftLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rightLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")

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
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        monitor.onChange = { [weak self] in self?.render() }
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
        rightLine.title = "Right: \(right)%"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
