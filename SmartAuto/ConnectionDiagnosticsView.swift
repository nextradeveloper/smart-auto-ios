import CoreLocation
import Network
import SwiftUI
import UIKit

enum ConnectionCheck: Equatable {
    case idle, running, passed(String), failed(String)

    var detail: String {
        switch self {
        case .idle: return "ยังไม่ได้ทดสอบ"
        case .running: return "กำลังทดสอบ…"
        case let .passed(text), let .failed(text): return text
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        default: return "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .passed: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

@MainActor
final class ConnectionDiagnostics: ObservableObject {
    @Published private(set) var networkAvailable: Bool?
    @Published private(set) var wifiAddress: String?
    @Published private(set) var cloud: ConnectionCheck = .idle
    @Published private(set) var dash: ConnectionCheck = .idle
    private var monitor: NWPathMonitor?
    private var cloudTask: Task<Void, Never>?
    private var dashTask: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let generation = self.generation
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if let previous = self.networkAvailable, previous != available {
                    self.cloudTask?.cancel()
                    self.dashTask?.cancel()
                    self.cloud = .idle
                    self.dash = .idle
                }
                self.networkAvailable = available
                self.refreshWiFi()
            }
        }
        monitor.start(queue: DispatchQueue(label: "smartauto.connection-check"))
        refreshWiFi()
    }

    func refreshWiFi() {
        let address = DashLocator.wifiIPv4() == nil ? nil : DashLocator.wifiAddressDescription()
        if address != wifiAddress {
            // An answer from another network must not describe the new connection.
            cloudTask?.cancel()
            dashTask?.cancel()
            cloud = .idle
            dash = .idle
        }
        wifiAddress = address
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        cloudTask?.cancel()
        dashTask?.cancel()
        cloud = .idle
        dash = .idle
    }

    func testCloud() {
        guard cloud != .running else { return }
        cloud = .running
        cloudTask = Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: URL(string: "https://m.zontes.com/BoxApp/ABROAD/")!)
                request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request)
                guard !Task.isCancelled else { return }
                cloud = Self.cloudResult(statusCode: (response as? HTTPURLResponse)?.statusCode)
            } catch {
                guard !Task.isCancelled else { return }
                cloud = .failed("ติดต่อไม่ได้ ลองใช้อินเทอร์เน็ตมือถือแล้วทดสอบอีกครั้ง")
            }
        }
    }

    static func cloudResult(statusCode: Int?) -> ConnectionCheck {
        guard let code = statusCode else {
            return .failed("ไม่ได้รับคำตอบที่ตรวจสอบได้ ลองอีกครั้ง")
        }
        guard (200..<500).contains(code) else {
            return .failed("เซิร์ฟเวอร์ตอบกลับแต่พบปัญหา (HTTP \(code)) ลองอีกครั้งภายหลัง")
        }
        return .passed("เซิร์ฟเวอร์ตอบกลับแล้ว ยังไม่ได้ตรวจบัญชีเข้าสู่ระบบ")
    }

    func testDash() {
        guard dash != .running else { return }
        dash = .running
        dashTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                DashLocator.locate(log: { EventLog.record("CHECK", $0) },
                                   isCancelled: { Task<Never, Never>.isCancelled })
            }
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            switch result {
            case .success: dash = .passed("จอรถตอบรับในการทดสอบล่าสุด")
            case .failure(.cancelled): dash = .idle
            case .failure(.noWifiAddress): dash = .failed("เชื่อมต่อ Wi-Fi ของรถในตั้งค่า iOS ก่อนทดสอบ")
            case .failure: dash = .failed("จอยังไม่ตอบรับ ตรวจ Wi-Fi รถและสิทธิ์เครือข่ายภายใน แล้วลองอีกครั้ง")
            }
        }
    }

    func cancelDashCheck() {
        dashTask?.cancel()
        dash = .idle
    }
}

struct ConnectionDiagnosticsView: View {
    @ObservedObject var bluetooth: VehicleBluetoothMonitor
    @ObservedObject var dashScreen: DashScreenService
    @StateObject private var checks = ConnectionDiagnostics()
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationStatus = CLLocationManager().authorizationStatus
    @State private var locationEnabled: Bool?

    var body: some View {
        List {
            Section {
                diagnosticRow("Bluetooth", detail: bluetooth.status.title,
                              symbol: bluetooth.status.isPositive ? "checkmark.circle.fill" : "exclamationmark.circle",
                              color: bluetooth.status.isPositive ? .green : .orange)
                Button("ค้นหา Bluetooth อีกครั้ง") { bluetooth.refresh() }
                    .disabled(bluetooth.status.isPositive || bluetooth.commandInProgress != nil)
                diagnosticRow("Wi-Fi", detail: checks.wifiAddress.map { "มีการเชื่อมต่อ Wi-Fi · \($0)" } ?? "ยังไม่มี IP บน Wi-Fi",
                              symbol: "wifi", color: checks.wifiAddress == nil ? .orange : .secondary)
                if dashScreen.isRunning {
                    diagnosticRow("จอรถ", detail: dashScreen.message.isEmpty ? dashScreen.state.title : dashScreen.message,
                                  symbol: dashScreen.state == .streaming ? "checkmark.circle.fill" : "exclamationmark.circle",
                                  color: dashScreen.state == .streaming ? .green : .orange)
                    if dashScreen.state != .streaming {
                        Button("หยุดจอแล้วทดสอบใหม่") {
                            dashScreen.stop()
                            checks.testDash()
                        }
                        .disabled(dashScreen.isMaintainingCache)
                    }
                } else {
                    checkRow("จอรถ", check: checks.dash)
                    if checks.dash == .running {
                        Button("ยกเลิกการทดสอบ") { checks.cancelDashCheck() }
                    } else {
                        Button("ทดสอบหาจอรถ") { checks.testDash() }
                            .disabled(dashScreen.isMaintainingCache)
                    }
                }
            } header: { Text("รถ") } footer: {
                Text(checks.dash == .running ? "กำลังรอจอตอบรับ อาจใช้เวลาประมาณ 1 นาที ยกเลิกได้จากปุ่มด้านบน" : "เลือก Wi-Fi ของรถในตั้งค่า iOS แล้วทดสอบหาจอ การทดสอบอาจปลุกจอรถ")
            }

            Section {
                diagnosticRow("เครือข่าย", detail: networkText, symbol: "network", color: .secondary)
                checkRow("เซิร์ฟเวอร์ ZONTES", check: checks.cloud)
                Button("ทดสอบเซิร์ฟเวอร์ ZONTES") { checks.testCloud() }
                    .disabled(checks.cloud == .running)
            } header: { Text("อินเทอร์เน็ต") } footer: {
                Text("Wi-Fi ของรถอาจไม่มีอินเทอร์เน็ต การทดสอบนี้ไม่ส่งรหัสผ่านหรือเซสชัน")
            }

            Section {
                diagnosticRow("ตำแหน่ง", detail: locationText, symbol: "location", color: .secondary)
                Button("เปิดตั้งค่าแอป") { openSettings() }
            } header: { Text("สิทธิ์ของแอป") } footer: {
                Text("หากค้นหารถหรือจอไม่พบ ให้ตรวจสิทธิ์ Bluetooth และเครือข่ายภายใน ส่วนการจำจุดจอดเบื้องหลังใช้สิทธิ์ตำแหน่งตลอดเวลา")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("ตรวจการเชื่อมต่อ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { checks.start(); refreshPermissions() }
        .onDisappear { checks.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { checks.refreshWiFi(); refreshPermissions() }
        }
        .onChange(of: dashScreen.isRunning) { running in
            if running { checks.cancelDashCheck() }
        }
    }

    private var networkText: String {
        switch checks.networkAvailable {
        case .some(true): return "มีช่องทางเชื่อมต่อ ทดสอบเซิร์ฟเวอร์เพื่อยืนยันอินเทอร์เน็ต"
        case .some(false): return "ยังไม่มีช่องทางเชื่อมต่อ"
        case .none: return "กำลังตรวจเครือข่าย…"
        }
    }

    private var locationText: String {
        if locationEnabled == false { return "ปิดบริการตำแหน่งบน iPhone" }
        switch locationStatus {
        case .authorizedAlways: return "อนุญาตตลอดเวลา"
        case .authorizedWhenInUse: return "อนุญาตขณะใช้แอป"
        case .notDetermined: return "ยังไม่ได้ขอสิทธิ์"
        case .denied, .restricted: return "ไม่ได้รับอนุญาต"
        @unknown default: return "ตรวจสิทธิ์ในตั้งค่า iOS"
        }
    }

    private func refreshPermissions() {
        locationStatus = CLLocationManager().authorizationStatus
        Task {
            locationEnabled = await Task.detached(priority: .utility) {
                CLLocationManager.locationServicesEnabled()
            }.value
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func checkRow(_ title: String, check: ConnectionCheck) -> some View {
        diagnosticRow(title, detail: check.detail, symbol: check.symbol, color: check.color, working: check == .running)
    }

    private func diagnosticRow(_ title: String, detail: String, symbol: String, color: Color, working: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if working {
                ProgressView().frame(width: 24).accessibilityLabel("กำลังทดสอบ")
            } else {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
