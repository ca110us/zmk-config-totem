import AppKit
import CoreBluetooth

enum Half {
    case left, right
}

/// Reads both halves' battery levels from the TOTEM while macOS keeps it connected.
///
/// Event driven to stay cheap: once connected it only wakes for battery level
/// notifications, which the keyboard sends when a level changes. While the keyboard
/// is away, e.g. asleep, a pending connection completes as soon as it is back; the
/// system handles that, so the app does not poll. Only a keyboard it has never seen
/// is looked for on a slow, tolerant timer.
final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let userDescription = CBUUID(string: CBUUIDCharacteristicUserDescriptionString)
    // This fork's firmware setting that slows the split link while the keyboard is idle
    private static let powerSavingService = CBUUID(string: "8FC697BD-5C61-4712-86DD-75B98EF03B7A")
    private static let powerSavingEnabled = CBUUID(string: "8FC697BE-5C61-4712-86DD-75B98EF03B7A")
    static let hasPowerSavingKey = "KeyboardHasPowerSaving"
    private static let keyboardIdentifierKey = "KeyboardIdentifier"
    private static let keyboardNamePrefix = "TOTEM"
    private static let retryInterval: TimeInterval = 60

    var onChange: (() -> Void)?
    private(set) var levels: [Half: Int] = [:]
    private(set) var isConnected = false
    /// The keyboard's idle power saving setting, or nil until it has been read
    private(set) var powerSaving: Bool?

    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var halfOf: [ObjectIdentifier: Half] = [:]
    private var powerSavingCharacteristic: CBCharacteristic?
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
        if let powerSavingCharacteristic {
            keyboard.readValue(for: powerSavingCharacteristic)
        }
    }

    func setPowerSaving(_ enabled: Bool) {
        guard let keyboard, let powerSavingCharacteristic else { return }
        // The menu shows the new state once it has been read back from the keyboard
        keyboard.writeValue(Data([enabled ? 1 : 0]), for: powerSavingCharacteristic, type: .withResponse)
    }

    @objc private func systemDidWake() {
        findKeyboard()
    }

    private func findKeyboard() {
        guard central.state == .poweredOn, !isConnected else { return }

        // The keyboard does not advertise while connected to the Mac, so ask the system
        // for peripherals it is already connected to instead of scanning.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        if let match = connected.first(where: { $0.name?.hasPrefix(Self.keyboardNamePrefix) == true }) {
            connect(match)
        } else if keyboard == nil, let known = knownKeyboard() {
            connect(known)
        } else if keyboard == nil {
            scheduleRetry()
        }
    }

    /// The keyboard this Mac has connected to before, even while it is away
    private func knownKeyboard() -> CBPeripheral? {
        guard let saved = UserDefaults.standard.string(forKey: Self.keyboardIdentifierKey),
              let identifier = UUID(uuidString: saved) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    /// Connects now if the keyboard is connected to the Mac, otherwise as soon as it is.
    /// Connection attempts never time out, so this also waits out the keyboard's sleep.
    private func connect(_ peripheral: CBPeripheral) {
        retryTimer?.invalidate()
        retryTimer = nil
        if let keyboard, keyboard !== peripheral {
            central.cancelPeripheralConnection(keyboard)
        }
        keyboard = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
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
        resetConnection()
    }

    private func resetConnection() {
        isConnected = false
        levels = [:]
        halfOf = [:]
        powerSavingCharacteristic = nil
        powerSaving = nil
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
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.keyboardIdentifierKey)
        isConnected = true
        onChange?()
        peripheral.discoverServices([Self.batteryService, Self.powerSavingService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === keyboard else { return }
        forgetKeyboard()
        scheduleRetry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === keyboard else { return }
        resetConnection()
        // Pick it up again the moment it reconnects, e.g. when it wakes from sleep
        central.connect(peripheral)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        let services = peripheral.services ?? []
        // ZMK exposes two battery services: the left half's own, and one relaying the right half
        for service in services where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
        if let service = services.first(where: { $0.uuid == Self.powerSavingService }) {
            peripheral.discoverCharacteristics([Self.powerSavingEnabled], for: service)
        } else {
            // Older firmware without the setting
            UserDefaults.standard.set(false, forKey: Self.hasPowerSavingKey)
            onChange?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The keyboard's services changed, e.g. after flashing new firmware; start over with the new ones
        halfOf = [:]
        powerSavingCharacteristic = nil
        powerSaving = nil
        peripheral.discoverServices([Self.batteryService, Self.powerSavingService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.batteryLevel:
                peripheral.discoverDescriptors(for: characteristic)
            case Self.powerSavingEnabled:
                powerSavingCharacteristic = characteristic
                UserDefaults.standard.set(true, forKey: Self.hasPowerSavingKey)
                peripheral.readValue(for: characteristic)
            default:
                break
            }
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
        if characteristic === powerSavingCharacteristic {
            guard error == nil, let value = characteristic.value?.first else { return }
            powerSaving = value != 0
            onChange?()
            return
        }
        guard let half = halfOf[ObjectIdentifier(characteristic)], let level = characteristic.value?.first else { return }
        // ZMK reports 0 for the right half until it has heard from it
        levels[half] = half == .right && level == 0 ? nil : Int(level)
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Read back what the keyboard actually stored, whether or not the write succeeded
        if characteristic === powerSavingCharacteristic {
            peripheral.readValue(for: characteristic)
        }
    }
}
