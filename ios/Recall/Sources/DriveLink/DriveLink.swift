import Foundation
import CoreBluetooth
import Combine

// Needs NSBluetoothAlwaysUsageDescription in Info.plist. Real iPhone only (the simulator has no Bluetooth).

final class DriveLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var statusText = "Starting Bluetooth"
    @Published private(set) var isConnected = false
    @Published private(set) var robot: RobotStatus?
    private var lastStatusReceivedAt: TimeInterval?

    /// A missing, disconnected, or stale telemetry sample is never treated as stopped.
    var isRobotStationary: Bool {
        StationaryStatus.isStationary(status: robot, connected: isConnected,
                                      receivedAt: lastStatusReceivedAt,
                                      now: ProcessInfo.processInfo.systemUptime)
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var heartbeat: Timer?
    private var session = DriveLinkSession()
    private var heartbeatSuspended = false
    /// Called for every well-formed status line (main queue). Used by the motion self-test to log each line with its receive time.
    var onStatus: ((RobotStatus) -> Void)?
    private var lines = LineBuffer()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Set wheel speeds (-255...255). The 10 Hz heartbeat keeps resending them.
    func drive(left: Int, right: Int) {
        session.drive(left: left, right: right)
    }

    /// Zero the heartbeat and send an immediate STOP.
    func stop() {
        session.stop()
        heartbeatSuspended = false
        send(DriveProtocol.stopCommand)
    }

    /// Self-test only (watchdog step): while suspended the 10 Hz heartbeat sends nothing, so the ESP32 must stop on its own.
    /// `stop()` and a disconnect clear it.
    func setHeartbeatSuspended(_ suspended: Bool) { heartbeatSuspended = suspended }

    private func send(_ s: String) {
        guard let p = peripheral, let rx else { return }
        p.writeValue(Data(s.utf8), for: rx, type: .withoutResponse)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: DriveProtocol.heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self, !self.heartbeatSuspended else { return }
            self.send(DriveProtocol.driveCommand(left: self.session.left, right: self.session.right))
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetConnection() {
        heartbeat?.invalidate()
        heartbeat = nil
        session.reset()
        heartbeatSuspended = false
        isConnected = false
        rx = nil; tx = nil
        robot = nil
        lastStatusReceivedAt = nil
        lines = LineBuffer()
    }

    private func failConnection(_ p: CBPeripheral, message: String) {
        stop()
        resetConnection()
        peripheral = nil
        central.cancelPeripheralConnection(p)
        statusText = message
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [Self.service]) }
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            statusText = "Scanning for Navigator"
            c.scanForPeripherals(withServices: [Self.service])
        } else {
            resetConnection()
            peripheral = nil
            statusText = "Bluetooth unavailable (state \(c.state.rawValue))"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard peripheral == nil, c.state == .poweredOn else { return }
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
        guard p === peripheral else { return }
        resetConnection()
        statusText = "Connected, finding service"
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        resetConnection()
        peripheral = nil
        statusText = "Disconnected, rescanning"
        if c.state == .poweredOn { c.scanForPeripherals(withServices: [Self.service]) }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        resetConnection()
        peripheral = nil
        statusText = "Connect failed, rescanning"
        if c.state == .poweredOn { c.scanForPeripherals(withServices: [Self.service]) }
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            failConnection(p, message: "Navigator service unavailable, rescanning")
            return
        }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === peripheral, s.uuid == Self.service else { return }
        guard error == nil else {
            failConnection(p, message: "Characteristic discovery failed, rescanning")
            return
        }
        for c in s.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID { tx = c }
        }
        guard let rx, rx.properties.contains(.writeWithoutResponse),
              let tx, tx.properties.contains(.notify) else {
            failConnection(p, message: "Required UART characteristics unavailable, rescanning")
            return
        }
        statusText = "Enabling Navigator status notifications"
        p.setNotifyValue(true, for: tx)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === tx else { return }
        guard error == nil, c.isNotifying, rx != nil else {
            failConnection(p, message: "Status notifications unavailable, rescanning")
            return
        }
        session.connect()
        isConnected = true
        statusText = "Linked to Navigator"
        stop()
        startHeartbeat()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === tx, error == nil,
              let d = c.value, let s = String(data: d, encoding: .utf8) else { return }
        for line in lines.append(s) {
            if let st = RobotStatus.parse(line) {
                robot = st
                lastStatusReceivedAt = ProcessInfo.processInfo.systemUptime
                onStatus?(st)
            }
        }
    }
}
