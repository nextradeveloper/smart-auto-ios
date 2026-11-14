import Combine
import Foundation

@MainActor
final class ZontesAppModel: ObservableObject {
    @Published private(set) var session: ZontesSession?
    @Published private(set) var vehicle: VehicleSnapshot? {
        didSet {
            guard oldValue?.carCode != vehicle?.carCode else { return }
            selectedStyle = vehicle.flatMap { VehicleStyleStore.load(pke: $0.carCode) }
        }
    }
    /// Model and colour the owner picked, matching the artwork in the official app.
    @Published private(set) var selectedStyle: MotorStyle?
    @Published private(set) var motorCatalog: [MotorCategory] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasNoVehicle = false
    @Published private(set) var busyText = ""
    @Published private(set) var commandInProgress: VehicleCommand?
    @Published var message: String?
    private let vehicleLoader: (ZontesSession) async throws -> VehicleSnapshot
    private let sessionClearer: () -> Void
    private var refreshTask: Task<VehicleSnapshot, Error>?
    private var refreshID = UUID()
    private var catalogTask: Task<[MotorCategory], Error>?

    init(session: ZontesSession? = ZontesSessionStore.load(),
         automaticallyRefresh: Bool = true,
         sessionClearer: @escaping () -> Void = { ZontesSessionStore.clear() },
         vehicleLoader: @escaping (ZontesSession) async throws -> VehicleSnapshot = { try await ZontesAPI.shared.vehicle(session: $0) }) {
        self.session = session
        self.vehicleLoader = vehicleLoader
        self.sessionClearer = sessionClearer
        if let session, session.isBluetoothOnly {
            vehicle = .bluetoothOnly(session)
            selectedStyle = VehicleStyleStore.load(pke: session.carCode)
        } else if session != nil && automaticallyRefresh {
            isBusy = true
            Task { await refresh() }
        }
    }

    func login(account: String, password: String) async {
        guard !account.isEmpty, !password.isEmpty else {
            message = "กรุณากรอกอีเมลและรหัสผ่าน"
            return
        }
        isBusy = true
        busyText = "กำลังเข้าสู่ระบบ…"
        defer {
            isBusy = false
            busyText = ""
        }
        do {
            let newSession = try await ZontesAPI.shared.login(account: account, password: password)
            try ZontesSessionStore.save(newSession)
            session = newSession
            busyText = "กำลังโหลดข้อมูลรถ…"
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Binds a vehicle from its pairing QR code, without a ZONTES account.
    func pair(with code: VehiclePairingCode) {
        let newSession = code.session
        do {
            try ZontesSessionStore.save(newSession)
        } catch {
            message = error.localizedDescription
            return
        }
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        hasNoVehicle = false
        session = newSession
        vehicle = .bluetoothOnly(newSession)
    }

    func refresh() async {
        await refreshVehicle(reportErrors: true)
    }

    private func refreshVehicle(reportErrors: Bool) async {
        guard let session, refreshTask == nil else { return }
        // Paired by QR code: nothing to fetch, the vehicle talks over Bluetooth.
        guard !session.isBluetoothOnly else { return }
        let id = UUID()
        refreshID = id
        let loader = vehicleLoader
        let task = Task { try await loader(session) }
        refreshTask = task
        if reportErrors {
            isBusy = true
            busyText = "กำลังโหลดข้อมูลรถ…"
        }
        defer {
            if refreshID == id {
                refreshTask = nil
                isBusy = false
                busyText = ""
            }
        }
        do {
            let fresh = try await task.value
            guard refreshID == id, self.session == session else { return }
            hasNoVehicle = false
            vehicle = fresh
        } catch {
            guard refreshID == id, self.session == session else { return }
            if let failure = error as? ZontesError {
                if failure == .authenticationRequired {
                    logout()
                    message = failure.localizedDescription
                    return
                }
                if failure == .missingVehicle {
                    vehicle = nil
                    hasNoVehicle = true
                    return
                }
            }
            if reportErrors && !(error is CancellationError) { message = error.localizedDescription }
        }
    }

    /// Fresh fuel, range and tyres for the dash, without the busy indicator or error messages.
    func refreshQuietly() async {
        await refreshVehicle(reportErrors: false)
    }

    func send(_ command: VehicleCommand) async {
        guard let session, let vehicle else {
            message = ZontesError.missingVehicle.localizedDescription
            return
        }
        commandInProgress = command
        defer { commandInProgress = nil }
        do {
            try await VehicleCommandClient.shared.send(command, session: session, vehicle: vehicle)
            message = "รถตอบรับคำสั่ง “\(command.title)” แล้ว"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    var vehicleImageURL: URL? { selectedStyle?.imageURL ?? vehicle?.imageURL }

    /// The picked style, or the catalog entry whose artwork the account uses.
    var vehicleStyle: MotorStyle? {
        if let selectedStyle { return selectedStyle }
        guard let file = vehicle?.imageURL?.lastPathComponent else { return nil }
        return motorCatalog.flatMap { $0.styles }.first { $0.imageURL.lastPathComponent == file }
    }

    var modelName: String {
        if let category = vehicleStyle?.category, !category.isEmpty { return "ZONTES \(category)" }
        if let name = vehicle?.name, !name.isEmpty { return name }
        return "ZONTES"
    }

    /// The owner's name for the vehicle, otherwise its model.
    var vehicleTitle: String {
        if let remark = vehicle?.remarkName, !remark.isEmpty { return remark }
        return modelName
    }

    /// Model and colour under the title, without repeating it.
    var vehicleSubtitle: String? {
        let candidate = vehicleStyle?.name ?? (vehicle?.remarkName.isEmpty == false ? modelName : nil)
        guard let detail = candidate, !detail.isEmpty, detail.uppercased() != vehicleTitle.uppercased() else { return nil }
        return detail
    }

    func loadMotorCatalog() async throws {
        guard motorCatalog.isEmpty else { return }
        if let catalogTask {
            motorCatalog = try await catalogTask.value
            return
        }
        let task = Task { try await ZontesAPI.shared.motorCatalog() }
        catalogTask = task
        defer { catalogTask = nil }
        motorCatalog = try await task.value
    }

    /// nil goes back to the account's artwork.
    func selectStyle(_ style: MotorStyle?) {
        guard let pke = vehicle?.carCode, !pke.isEmpty else { return }
        VehicleStyleStore.save(style, pke: pke)
        selectedStyle = style
    }

    func logout() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isBusy = false
        busyText = ""
        sessionClearer()
        session = nil
        vehicle = nil
        hasNoVehicle = false
        message = nil
    }
}
