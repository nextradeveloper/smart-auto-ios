import CoreBluetooth
import Combine
import Foundation

@MainActor
final class VehicleBluetoothMonitor: NSObject, ObservableObject {
    enum Status: Equatable {
        case unavailable
        case unauthorized
        case poweredOff
        case ready
        case scanning
        case nearby(String)
        case connected(String)

        var title: String {
            switch self {
            case .unavailable: return "ไม่รองรับ"
            case .unauthorized: return "ไม่ได้รับอนุญาต"
            case .poweredOff: return "ปิดอยู่"
            case .ready: return "พร้อมใช้งาน"
            case .scanning: return "กำลังค้นหา"
            case .nearby: return "พบรถใกล้เคียง"
            case .connected: return "เชื่อมต่อแล้ว"
            }
        }

        var symbol: String {
            switch self {
            case .connected: return "bolt.horizontal.circle.fill"
            case .nearby: return "dot.radiowaves.left.and.right"
            case .scanning: return "antenna.radiowaves.left.and.right"
            case .ready: return "checkmark.circle.fill"
            case .poweredOff, .unavailable, .unauthorized: return "exclamationmark.circle.fill"
            }
        }

        var isPositive: Bool {
            switch self {
            case .connected, .nearby: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .unavailable

    private static let vehicleServices = [
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "A041"),
    ]

    private var central: CBCentralManager!
    private var scanGeneration = 0

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func refresh() {
        guard central.state == .poweredOn else {
            update(for: central.state)
            return
        }
        inspectConnectionAndScan()
    }

    private func update(for state: CBManagerState) {
        switch state {
        case .poweredOn:
            inspectConnectionAndScan()
        case .poweredOff, .resetting:
            stopScanning()
            status = .poweredOff
        case .unauthorized:
            stopScanning()
            status = .unauthorized
        case .unsupported:
            stopScanning()
            status = .unavailable
        case .unknown:
            status = .unavailable
        @unknown default:
            status = .unavailable
        }
    }

    private func inspectConnectionAndScan() {
        let connected = central.retrieveConnectedPeripherals(withServices: Self.vehicleServices)
        if let peripheral = connected.first {
            stopScanning()
            status = .connected(displayName(for: peripheral))
            return
        }

        scanGeneration += 1
        let generation = scanGeneration
        status = .scanning
        central.stopScan()
        central.scanForPeripherals(
            withServices: Self.vehicleServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, generation == self.scanGeneration else { return }
            self.central.stopScan()
            if self.status == .scanning { self.status = .ready }
        }
    }

    private func stopScanning() {
        scanGeneration += 1
        central?.stopScan()
    }

    private func displayName(for peripheral: CBPeripheral, advertisedName: String? = nil) -> String {
        let name = advertisedName ?? peripheral.name
        return name?.isEmpty == false ? name! : "ZONTES"
    }
}

extension VehicleBluetoothMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in self?.update(for: central.state) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.scanGeneration += 1
            self.status = .nearby(self.displayName(for: peripheral, advertisedName: advertisedName))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = .connected(self.displayName(for: peripheral))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in self?.inspectConnectionAndScan() }
    }
}
