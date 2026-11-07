import CoreBluetooth
import Combine
import Foundation

// ZONTES Smart 1.12 BLE authentication (vf9.a). The key mixes in the vehicle's 6-digit
// Bluetooth password: the factory value is the PKE code's last six characters, and binding
// in the official app replaces it with one the owner chooses.
enum LegacyBluetoothProtocol {
    /// Version query. The official app sends it after a refused action to tell a wrong
    /// password apart from a refused action; it moves nothing on the vehicle.
    static let versionQuery = "10"

    static func isValidPassword(_ password: String) -> Bool {
        password.utf8.count == 6 && password.utf8.allSatisfy { (48...57).contains($0) }
    }

    enum Response: Equatable {
        case challenge(String)
        case acknowledged
        case rejected
        case ignored
    }

    static func response(fields: [String], pke: String, action: String, awaitingChallenge: Bool) -> Response {
        guard fields.count >= 5, fields[1] == pke, fields[2] == "10" else { return .ignored }
        if awaitingChallenge, ["*AT", "*BT"].contains(fields[0]), fields[3] == "008" {
            let value = fields[4]
            guard value.utf8.count == 8, value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { return .ignored }
            return .challenge(value)
        }
        guard !awaitingChallenge, fields[0] == "*AT", fields[3] == "001", fields[4] == action else { return .ignored }
        if fields.count == 5 { return .acknowledged }
        // As in the official app, a trailing 0 is a refusal for every action.
        if fields.last == "0" { return .rejected }
        if fields[5] == "1" { return .acknowledged }
        // The version query answers with version data instead of a status flag.
        return action == versionQuery ? .acknowledged : .ignored
    }

    static func packet(action: String, pke: String, mcu: String, challenge: String, password: String) throws -> Data {
        func hex(_ string: String, count: Int) throws -> [UInt8] {
            guard string.utf8.count == count * 2 else { throw ZontesError.invalidVehicleKey }
            var result = [UInt8]()
            var index = string.startIndex
            while index < string.endIndex {
                let end = string.index(index, offsetBy: 2)
                guard let byte = UInt8(string[index..<end], radix: 16) else { throw ZontesError.invalidVehicleKey }
                result.append(byte)
                index = end
            }
            return result
        }
        let code = Array(pke.utf8)
        guard (1...64).contains(code.count), code.allSatisfy({ (33...126).contains($0) && $0 != 44 && $0 != 35 }),
              ["1", "2", "5", "6", versionQuery].contains(action) else { throw ZontesError.invalidVehicleKey }
        let seed = try hex(mcu, count: 16)
        let nonce = try hex(challenge, count: 4)
        let passwordBytes = try hex(password, count: 3)
        var key = [UInt8](try LegacyRemoteProtocol.aesECBEncrypt(Data(seed), key: Data("TAYOBTa1YCWc2gTS".utf8)))
        for i in 0..<4 { key[12 + i] ^= nonce[i] }
        for i in 0..<3 { key[i] ^= passwordBytes[i] }
        var block = Array(code.prefix(15))
        block += Array(repeating: 0, count: 16 - block.count)
        let signature = try LegacyRemoteProtocol.aesECBEncrypt(Data(block), key: Data(key))
            .map { String(format: "%02x", $0) }.joined()
        return Data("*BT,\(pke),10,001,\(action),\(signature)#".utf8)
    }
}

@MainActor
final class VehicleBluetoothMonitor: NSObject, ObservableObject {
    enum Status: Equatable {
        case unavailable, unauthorized, poweredOff, ready, scanning, connecting, connected(String)
        var title: String {
            switch self {
            case .unavailable: return "ไม่พร้อมใช้งาน"
            case .unauthorized: return "ไม่ได้รับอนุญาต"
            case .poweredOff: return "ปิดอยู่"
            case .ready: return "ยังไม่เชื่อมต่อ"
            case .scanning: return "กำลังค้นหารถ"
            case .connecting: return "กำลังเชื่อมต่อ"
            case .connected: return "เชื่อมต่อแล้ว"
            }
        }
        var symbol: String { isPositive ? "bolt.horizontal.circle.fill" : "antenna.radiowaves.left.and.right" }
        var isPositive: Bool { if case .connected = self { return true }; return false }
    }
    @Published private(set) var status: Status = .unavailable
    @Published private(set) var commandInProgress: VehicleCommand?
    @Published private(set) var isCheckingPassword = false
    var isBusy: Bool { commandInProgress != nil || isCheckingPassword }
    private let serviceID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let writeID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let notifyID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var pke = ""
    private var mcu = ""
    private var frameBuffer = ""
    private var continuation: CheckedContinuation<Void, Error>?
    private var action = ""
    private var password = ""
    private var phase = 0 // 0 idle, 1 challenge, 2 action submitted
    private var chunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var writePending = false
    private var generation = 0
    private var operationID = 0
    private var notificationCount = 0
    private var ignoredFrameCount = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func configure(pke: String, mcu: String) {
        guard self.pke != pke || self.mcu != mcu else { return }
        generation += 1
        finish(ZontesError.commandConnectionClosed)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        self.peripheral = nil
        writer = nil
        self.pke = pke.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mcu = mcu.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    func refresh() {
        guard central.state == .poweredOn else { update(central.state); return }
        guard !pke.isEmpty else { status = .ready; return }
        if status.isPositive || status == .connecting { return }
        generation += 1
        let current = generation
        central.stopScan()
        status = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == current, self.status == .scanning else { return }
            self.central.stopScan()
            self.status = .ready
        }
    }

    func send(_ command: VehicleCommand) async throws {
        try ensureIdle()
        let action: String
        switch command {
        case .lock: action = "1"
        case .unlock: action = "2"
        case .fuelLid: action = "5"
        case .seat: action = "6"
        case .find: throw ZontesError.message("ค้นหารถใช้การเชื่อมต่อระบบรถ")
        }
        let password = BluetoothPasswordStore.load(pke: pke) ?? String(pke.suffix(6))
        commandInProgress = command
        defer { commandInProgress = nil }
        do {
            try await perform(action, password: password)
        } catch ZontesError.commandRejected {
            do {
                try await perform(LegacyBluetoothProtocol.versionQuery, password: password)
            } catch ZontesError.commandRejected {
                throw ZontesError.bluetoothPasswordRejected
            } catch {}
            throw ZontesError.commandRejected
        }
    }

    /// Checks a password with the version query and keeps it for this vehicle if it is right.
    func verifyPassword(_ password: String) async throws {
        try ensureIdle()
        guard LegacyBluetoothProtocol.isValidPassword(password) else {
            throw ZontesError.message("รหัส Bluetooth ต้องเป็นตัวเลข 6 หลัก")
        }
        let target = pke
        isCheckingPassword = true
        defer { isCheckingPassword = false }
        do {
            try await perform(LegacyBluetoothProtocol.versionQuery, password: password)
        } catch ZontesError.commandRejected {
            throw ZontesError.bluetoothPasswordRejected
        }
        try BluetoothPasswordStore.save(password, pke: target)
    }

    private func ensureIdle() throws {
        guard status.isPositive, writer != nil else { throw ZontesError.message("กรุณาเชื่อมต่อ Bluetooth กับรถก่อน") }
        guard continuation == nil, !isBusy else { throw ZontesError.message("กำลังส่งคำสั่งอื่นอยู่") }
    }

    private func perform(_ action: String, password: String) async throws {
        guard pke.count >= 6 else { throw ZontesError.invalidVehicleKey }
        guard continuation == nil else { throw ZontesError.message("กำลังส่งคำสั่งอื่นอยู่") }
        self.action = action
        self.password = password
        phase = 1
        notificationCount = 0
        ignoredFrameCount = 0
        operationID += 1
        let operation = operationID
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            continuation = pending
            enqueue(Data("*BT,\(pke),10,008#".utf8))
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.generation == current, self.operationID == operation, self.continuation != nil else { return }
                let text: String
                if self.phase == 2 {
                    text = "ส่งคำสั่งแล้ว แต่ยังไม่ได้รับการยืนยัน กรุณาตรวจสอบรถก่อนลองอีกครั้ง"
                } else if self.notificationCount == 0 {
                    text = "เชื่อมต่อ Bluetooth แล้ว แต่ไม่มีข้อมูลตอบกลับจากรถ กรุณาปิดแอป Zontes Smart แล้วเชื่อมต่อใหม่"
                } else {
                    text = "ได้รับข้อมูล Bluetooth แต่ยังยืนยันตัวรถไม่ได้ (ข้อมูลที่ไม่ตรง \(self.ignoredFrameCount) รายการ) กรุณาติดต่อผู้พัฒนา"
                }
                self.finish(ZontesError.message(text))
            }
        }
    }

    private func update(_ state: CBManagerState) {
        switch state {
        case .poweredOn: refresh()
        case .poweredOff, .resetting: disconnect(); status = .poweredOff
        case .unauthorized: disconnect(); status = .unauthorized
        default: disconnect(); status = .unavailable
        }
    }

    private func disconnect() {
        generation += 1
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; writer = nil; chunks.removeAll(); writePending = false; frameBuffer = ""
        finish(ZontesError.commandConnectionClosed)
    }

    private func finish(_ error: Error? = nil) {
        guard let pending = continuation else { return }
        continuation = nil; phase = 0; password = ""
        if let error { chunks.removeAll(); pending.resume(throwing: error) } else { pending.resume() }
    }

    /// Frame text for the app log: PKE code masked, signature dropped.
    private func logFrame(_ direction: String, _ frame: String) {
        var fields = frame.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if fields.count > 1, fields[1] == pke { fields[1] = "<PKE>" }
        if fields.first == "*BT", fields.count == 6 { fields[5] = "<sig>#" }
        EventLog.record("BLE", "\(direction) \(fields.joined(separator: ","))")
    }

    private func enqueue(_ data: Data) {
        logFrame("TX", String(decoding: data, as: UTF8.self))
        guard let peripheral, let writer else { finish(ZontesError.commandConnectionClosed); return }
        writeType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        let length = peripheral.maximumWriteValueLength(for: writeType)
        guard length > 0 else { finish(ZontesError.commandConnectionClosed); return }
        chunks.append(contentsOf: stride(from: 0, to: data.count, by: length).map { data.subdata(in: $0..<min($0 + length, data.count)) })
        writeNext()
    }

    private func writeNext() {
        guard let peripheral, let writer else { finish(ZontesError.commandConnectionClosed); return }
        guard !writePending else { return }
        while !chunks.isEmpty {
            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            peripheral.writeValue(chunks.removeFirst(), for: writer, type: writeType)
            if writeType == .withResponse { writePending = true; return }
        }
    }

    private func receive(_ data: Data) {
        if continuation != nil { notificationCount += 1 }
        frameBuffer += String(decoding: data, as: UTF8.self)
        if frameBuffer.count > 4096 { frameBuffer = ""; finish(ZontesError.invalidResponse); return }
        while let end = frameBuffer.firstIndex(of: "#") {
            let raw = String(frameBuffer[...end]); frameBuffer.removeSubrange(...end)
            guard let start = raw.lastIndex(of: "*") else { continue }
            logFrame("RX", String(raw[start...]))
            let fields = raw[start...].dropLast().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard phase == 1 || phase == 2 else { continue }
            switch LegacyBluetoothProtocol.response(fields: fields, pke: pke, action: action, awaitingChallenge: phase == 1) {
            case let .challenge(value):
                do {
                    let packet = try LegacyBluetoothProtocol.packet(action: action, pke: pke, mcu: mcu, challenge: value, password: password)
                    phase = 2
                    enqueue(packet)
                } catch { finish(error) }
            case .acknowledged: finish()
            case .rejected: finish(ZontesError.commandRejected)
            case .ignored: ignoredFrameCount += 1
            }
        }
    }
}

extension VehicleBluetoothMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor [weak self] in self?.update(central.state) } }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).values.reduce(into: Data()) { $0.append($1) }
        Task { @MainActor [weak self] in
            guard let self, self.status == .scanning else { return }
            let target = self.pke.uppercased()
            let bytes = manufacturer + serviceData
            let raw = bytes.map { String(format: "%02X", $0) }.joined()
            let ascii = String(decoding: bytes, as: UTF8.self).uppercased()
            let targetHex = Data(target.utf8).map { String(format: "%02X", $0) }.joined()
            let simpleName = name.uppercased().filter { $0.isLetter || $0.isNumber }
            guard target.count >= 6, raw.contains(target) || raw.contains(targetHex) || ascii.contains(target) || simpleName == "PKE" + target.suffix(4) else { return }
            self.central.stopScan(); self.status = .connecting; self.peripheral = peripheral
            peripheral.delegate = self
            self.central.connect(peripheral)
            let current = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak peripheral] in
                guard let self, let peripheral, self.generation == current, self.status == .connecting else { return }
                self.central.cancelPeripheralConnection(peripheral); self.peripheral = nil; self.status = .ready
            }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in guard let self, self.peripheral === peripheral else { return }; peripheral.discoverServices([self.serviceID]) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in guard let self, self.peripheral === peripheral else { return }; self.disconnect(); self.status = .ready }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in guard let self, self.peripheral === peripheral else { return }; self.disconnect(); self.status = .ready }
    }
}

extension VehicleBluetoothMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == self.serviceID }) else { self.disconnect(); self.status = .ready; return }
            peripheral.discoverCharacteristics([self.writeID, self.notifyID], for: service)
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral else { return }
            guard error == nil, let write = service.characteristics?.first(where: { $0.uuid == self.writeID }),
                  !write.properties.intersection([.write, .writeWithoutResponse]).isEmpty,
                  let notify = service.characteristics?.first(where: { $0.uuid == self.notifyID }),
                  !notify.properties.intersection([.notify, .indicate]).isEmpty else { self.disconnect(); self.status = .ready; return }
            self.writer = write; peripheral.setNotifyValue(true, for: notify)
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, characteristic.uuid == self.notifyID else { return }
            guard error == nil, characteristic.isNotifying, self.writer != nil else { self.disconnect(); self.status = .ready; return }
            self.status = .connected(peripheral.name ?? "ZONTES")
            self.enqueue(Data("*BT,\(self.pke),10,001,7#".utf8))
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, characteristic.uuid == self.notifyID else { return }
            if let error { self.finish(error); return }
            if let data = characteristic.value { self.receive(data) }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, characteristic.uuid == self.writeID else { return }
            self.writePending = false
            if let error { self.finish(error); self.disconnect(); self.status = .ready; return }; self.writeNext()
        }
    }
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in guard let self, self.peripheral === peripheral else { return }; self.writeNext() }
    }
}
