import SwiftUI
import CoreBluetooth

// Add to Info.plist: NSBluetoothAlwaysUsageDescription = "Connects to the Navigator robot"
// Must run on a real iPhone (the simulator has no Bluetooth).

final class RobotLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published var status = "Starting Bluetooth"
    @Published var robotReply = ""
    @Published var isConnected = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var heartbeat: Timer?
    private var left = 0, right = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // Set the wheel speeds (-255...255). The heartbeat keeps sending them.
    func drive(left: Int, right: Int) {
        self.left = max(-255, min(255, left))
        self.right = max(-255, min(255, right))
    }
    func stop() { drive(left: 0, right: 0) }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        // 10 Hz, well inside the ESP32's 300 ms watchdog
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.peripheral, let rx = self.rx else { return }
            let msg = "\(self.left),\(self.right)\n"
            p.writeValue(Data(msg.utf8), for: rx, type: .withoutResponse)
        }
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            status = "Scanning for Navigator"
            c.scanForPeripherals(withServices: [Self.service])
        } else {
            status = "Bluetooth unavailable (state \(c.state.rawValue))"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        peripheral = p
        p.delegate = self
        c.stopScan()
        status = "Connecting"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Connected, finding service"
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        heartbeat?.invalidate()
        rx = nil
        status = "Disconnected, rescanning"
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
            status = "Linked to Navigator"
            startHeartbeat()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let d = c.value, let s = String(data: d, encoding: .utf8) { robotReply = s }
    }
}

struct ContentView: View {
    @StateObject private var link = RobotLink()
    private let speed = 150

    var body: some View {
        VStack(spacing: 20) {
            Text(link.status).font(.headline)
            Text(link.robotReply).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)

            // Press and hold: drives while held, stops on release.
            HoldButton(title: "Forward") { link.drive(left: speed, right: speed) } onRelease: { link.stop() }
            HStack(spacing: 20) {
                HoldButton(title: "Left")  { link.drive(left: -speed, right: speed) } onRelease: { link.stop() }
                HoldButton(title: "Right") { link.drive(left: speed, right: -speed) } onRelease: { link.stop() }
            }
            HoldButton(title: "Back") { link.drive(left: -speed, right: -speed) } onRelease: { link.stop() }
        }
        .padding()
    }
}

struct HoldButton: View {
    let title: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var down = false

    var body: some View {
        Text(title)
            .frame(width: 120, height: 60)
            .background(down ? Color.blue : Color.gray.opacity(0.3))
            .foregroundColor(down ? .white : .primary)
            .cornerRadius(12)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; onPress() } }
                .onEnded { _ in down = false; onRelease() })
    }
}
