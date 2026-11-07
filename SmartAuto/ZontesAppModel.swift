import Combine
import Foundation

@MainActor
final class ZontesAppModel: ObservableObject {
    @Published private(set) var session: ZontesSession?
    @Published private(set) var vehicle: VehicleSnapshot?
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

    func logout() {
        ZontesSessionStore.clear()
        session = nil
        vehicle = nil
        message = nil
    }
}
