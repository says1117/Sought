import Foundation
import CoreBluetooth

// Needs NSBluetoothAlwaysUsageDescription in Info.plist. Real iPhone only (the simulator has no Bluetooth).

final class DriveLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var statusText = "Starting Bluetooth"
    @Published private(set) var isConnected = false
    @Published private(set) var robot: RobotStatus?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var heartbeat: Timer?
    private var left = 0, right = 0
    private var lines = LineBuffer()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Set wheel speeds (-255...255). The 10 Hz heartbeat keeps resending them.
    func drive(left: Int, right: Int) {
        self.left = DriveProtocol.clamp(left)
        self.right = DriveProtocol.clamp(right)
    }

    /// Zero the heartbeat and send an immediate STOP.
    func stop() {
        left = 0; right = 0
        send(DriveProtocol.stopCommand)
    }

    private func send(_ s: String) {
        guard let p = peripheral, let rx else { return }
        p.writeValue(Data(s.utf8), for: rx, type: .withoutResponse)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: DriveProtocol.heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(DriveProtocol.driveCommand(left: self.left, right: self.right))
        }
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            statusText = "Scanning for Navigator"
            c.scanForPeripherals(withServices: [Self.service])
        } else {
            statusText = "Bluetooth unavailable (state \(c.state.rawValue))"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        guard PeripheralMatch.isNavigator(advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                                          cachedName: p.name,
                                          advertisedServiceUUIDs: uuids) else { return }
        peripheral = p
        p.delegate = self
        c.stopScan()
        statusText = "Connecting"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        statusText = "Connected, finding service"
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        heartbeat?.invalidate()
        rx = nil
        left = 0; right = 0
        robot = nil
        statusText = "Disconnected, rescanning"
        c.scanForPeripherals(withServices: [Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        statusText = "Connect failed, rescanning"
        c.scanForPeripherals(withServices: [Self.service])
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { return }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID { p.setNotifyValue(true, for: c) }
        }
        if rx != nil {
            isConnected = true
            statusText = "Linked to Navigator"
            startHeartbeat()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.txUUID, let d = c.value, let s = String(data: d, encoding: .utf8) else { return }
        for line in lines.append(s) {
            if let st = RobotStatus.parse(line) { robot = st }
        }
    }
}
