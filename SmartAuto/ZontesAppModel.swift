import Combine
import Foundation

@MainActor
final class ZontesAppModel: ObservableObject {
    @Published private(set) var session: ZontesSession?
    @Published private(set) var vehicle: VehicleSnapshot? {
        didSet {
            guard oldValue?.carCode != vehicle?.carCode else { return }
            selectedStyle = vehicle.flatMap { VehicleStyleStore.load(pke: $0.carCode) }
            // The catalog names the model when the account gives no name.
            if vehicle != nil { Task { try? await loadMotorCatalog() } }
        }
    }
    /// Model and colour the owner picked, matching the artwork in the official app.
    @Published private(set) var selectedStyle: MotorStyle?
    @Published private(set) var motorCatalog: [MotorCategory] = []
    @Published private(set) var isBusy = false
    @Published private(set) var busyText = ""
    @Published private(set) var commandInProgress: VehicleCommand?
    @Published var message: String?

    init() {
        session = ZontesSessionStore.load()
        if session != nil {
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
            vehicle = try await ZontesAPI.shared.vehicle(session: newSession)
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard let session else { return }
        isBusy = true
        busyText = "กำลังโหลดข้อมูลรถ…"
        defer {
            isBusy = false
            busyText = ""
        }
        do {
            vehicle = try await ZontesAPI.shared.vehicle(session: session)
        } catch {
            message = error.localizedDescription
        }
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
        motorCatalog = try await ZontesAPI.shared.motorCatalog()
    }

    /// nil goes back to the account's artwork.
    func selectStyle(_ style: MotorStyle?) {
        guard let pke = vehicle?.carCode, !pke.isEmpty else { return }
        VehicleStyleStore.save(style, pke: pke)
        selectedStyle = style
    }

    func logout() {
        ZontesSessionStore.clear()
        session = nil
        vehicle = nil
        message = nil
    }
}
