import AppKit
import CoreBluetooth

enum Half {
    case left, right
}

/// Reads both halves' battery levels from the TOTEM while macOS keeps it connected.
///
/// Event driven to stay cheap: once connected it only wakes for battery level
/// notifications, which the keyboard sends when a level changes. While the keyboard
/// is away it checks again on a slow, tolerant timer and right after the Mac wakes.
final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let userDescription = CBUUID(string: CBUUIDCharacteristicUserDescriptionString)
    private static let keyboardNamePrefix = "TOTEM"
    private static let retryInterval: TimeInterval = 60

    var onChange: (() -> Void)?
    private(set) var levels: [Half: Int] = [:]
    private(set) var isConnected = false

    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var halfOf: [ObjectIdentifier: Half] = [:]
    private var retryTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func refresh() {
        guard let keyboard, isConnected else {
            findKeyboard()
            return
        }
        for service in keyboard.services ?? [] {
            for characteristic in service.characteristics ?? [] where halfOf[ObjectIdentifier(characteristic)] != nil {
                keyboard.readValue(for: characteristic)
            }
        }
    }

    @objc private func systemDidWake() {
        findKeyboard()
    }

    private func findKeyboard() {
        guard central.state == .poweredOn, keyboard == nil else { return }

        // The keyboard does not advertise while connected to the Mac, so ask the system
        // for peripherals it is already connected to instead of scanning.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        guard let match = connected.first(where: { $0.name?.hasPrefix(Self.keyboardNamePrefix) == true }) else {
            scheduleRetry()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil
        keyboard = match
        match.delegate = self
        central.connect(match)
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: Self.retryInterval, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.findKeyboard()
        }
        // Let macOS coalesce this wakeup with others
        timer.tolerance = Self.retryInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func forgetKeyboard() {
        keyboard = nil
        isConnected = false
        levels = [:]
        halfOf = [:]
        onChange?()
    }

    private func track(_ characteristic: CBCharacteristic, as half: Half) {
        guard let keyboard else { return }
        halfOf[ObjectIdentifier(characteristic)] = half
        keyboard.setNotifyValue(true, for: characteristic)
        keyboard.readValue(for: characteristic)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            findKeyboard()
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            forgetKeyboard()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        onChange?()
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forgetKeyboard()
        scheduleRetry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        forgetKeyboard()
        scheduleRetry()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // ZMK exposes two battery services: the left half's own, and one relaying the right half
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.batteryLevel {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        // The relayed level carries a "Peripheral N" user description; the left half's own has none
        if let description = characteristic.descriptors?.first(where: { $0.uuid == Self.userDescription }) {
            peripheral.readValue(for: description)
        } else {
            track(characteristic, as: .left)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid == Self.userDescription, let characteristic = descriptor.characteristic else { return }
        let label = descriptor.value as? String ?? ""
        track(characteristic, as: label.hasPrefix("Peripheral") ? .right : .left)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let half = halfOf[ObjectIdentifier(characteristic)], let level = characteristic.value?.first else { return }
        // ZMK reports 0 for the right half until it has heard from it
        levels[half] = half == .right && level == 0 ? nil : Int(level)
        onChange?()
    }
}
