import AppKit
import UserNotifications

/// Posts a notification when a half runs low, or when the keyboard or its right half
/// drops its connection.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    /// Alert once below each threshold, lowest last
    private static let lowThresholds = [20, 10]
    /// A half must charge back above this before low battery alerts fire again,
    /// so a level wobbling around a threshold does not alert repeatedly
    private static let rearmLevel = 25
    /// Short drops that reconnect on their own within this time are not reported
    private static let disconnectGrace: TimeInterval = 30

    static let lowBatteryKey = "LowBatteryAlerts"
    static let disconnectKey = "DisconnectAlerts"

    private let center = UNUserNotificationCenter.current()
    private var alertedThreshold: [Half: Int] = [:]
    private var lastLevels: [Half: Int] = [:]
    private var wasConnected = false
    private var pendingDisconnect: (kind: DisconnectKind, timer: Timer)?
    private var isSleeping = false

    private enum DisconnectKind {
        case keyboard, rightHalf
    }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.lowBatteryKey: true, Self.disconnectKey: true])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Bluetooth drops while the Mac goes to sleep are expected, not worth an alert
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func update(levels: [Half: Int], isConnected: Bool) {
        checkLowBattery(levels)
        checkConnection(levels: levels, isConnected: isConnected)
        lastLevels = levels
        wasConnected = isConnected
    }

    private func checkLowBattery(_ levels: [Half: Int]) {
        for (half, level) in levels {
            if level >= Self.rearmLevel {
                alertedThreshold[half] = nil
                continue
            }
            guard let crossed = Self.lowThresholds.filter({ level < $0 }).min() else { continue }
            if let alerted = alertedThreshold[half], alerted <= crossed { continue }

            alertedThreshold[half] = crossed
            guard UserDefaults.standard.bool(forKey: Self.lowBatteryKey) else { continue }
            let urgency = crossed <= 10 ? "Charge it soon." : "Time to charge."
            post(id: "low-\(half)", title: "TOTEM battery low", body: "\(half.name) half: \(level)%. \(urgency)")
        }
    }

    private func checkConnection(levels: [Half: Int], isConnected: Bool) {
        guard isConnected else {
            if wasConnected {
                scheduleDisconnect(.keyboard)
            }
            return
        }

        if pendingDisconnect?.kind == .keyboard {
            cancelPendingDisconnect()
        }
        if levels[.right] != nil {
            if pendingDisconnect?.kind == .rightHalf {
                cancelPendingDisconnect()
            }
        } else if lastLevels[.right] != nil {
            // The left half reports 0 for the right half once their link drops
            scheduleDisconnect(.rightHalf)
        }
    }

    private func scheduleDisconnect(_ kind: DisconnectKind) {
        guard !isSleeping else { return }
        cancelPendingDisconnect()
        let timer = Timer(timeInterval: Self.disconnectGrace, repeats: false) { [weak self] _ in
            self?.pendingDisconnect = nil
            self?.postDisconnect(kind)
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pendingDisconnect = (kind, timer)
    }

    private func cancelPendingDisconnect() {
        pendingDisconnect?.timer.invalidate()
        pendingDisconnect = nil
    }

    private func postDisconnect(_ kind: DisconnectKind) {
        guard UserDefaults.standard.bool(forKey: Self.disconnectKey) else { return }
        switch kind {
        case .keyboard:
            post(id: "disconnect", title: "TOTEM disconnected",
                 body: "The keyboard is no longer connected to this Mac.")
        case .rightHalf:
            post(id: "disconnect", title: "TOTEM right half disconnected",
                 body: "The right half lost its link to the left half, so its keys may not respond.")
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Reusing the identifier replaces an older notification of the same kind
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    @objc private func willSleep() {
        isSleeping = true
        cancelPendingDisconnect()
    }

    @objc private func didWake() {
        isSleeping = false
    }

    // Show banners even though a menu bar app never counts as being in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension Half {
    var name: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}
