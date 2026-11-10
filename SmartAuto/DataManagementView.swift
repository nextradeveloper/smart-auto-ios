import SwiftUI
import UniformTypeIdentifiers

enum AppDataFiles {
    static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    static func clearMapCache() throws {
        try removeIfPresent(DashTiles.folder)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try removeIfPresent(caches.appendingPathComponent("DashMaps", isDirectory: true))
    }
}

struct HistoryExport: Codable {
    struct Trip: Codable {
        let summary: TripSummary
        let points: [TripPoint]
    }

    let version: Int
    let exportedAt: Date
    let trips: [Trip]
    let fuel: [FuelFill]

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

private struct HistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum DataRemoval: String, Identifiable {
    case cache, parking, trips, fuel, recent, log, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cache: return "ล้างแคชรูปและแผนที่"
        case .parking: return "ลบจุดจอดที่บันทึกไว้"
        case .trips: return "ลบทริปทั้งหมด"
        case .fuel: return "ลบการเติมน้ำมันทั้งหมด"
        case .recent: return "ลบสถานที่ล่าสุด"
        case .log: return "ล้างบันทึกการทำงาน"
        case .history: return "ลบประวัติทั้งหมด"
        }
    }

    var detail: String {
        switch self {
        case .cache: return "ล้างภาพรถและแผนที่ที่แอปเก็บไว้ชั่วคราว แผนที่จะต้องโหลดใหม่เมื่อใช้งาน ประวัติและบัญชียังคงอยู่"
        case .parking: return "ลบจุดจอดของรถทุกคันที่แอปเคยบันทึกในเครื่อง จุดจอดใหม่ยังบันทึกได้เมื่อมีการล็อกหรือออกห่างจากรถ"
        case .trips: return "ลบประวัติทริป พิกัด และข้อมูลถนนของทุกบัญชีในเครื่อง กู้คืนจากแอปไม่ได้"
        case .fuel: return "ลบรายการเติมน้ำมันและข้อมูลคำนวณอัตราสิ้นเปลืองของทุกบัญชีในเครื่อง กู้คืนจากแอปไม่ได้"
        case .recent: return "ลบสถานที่ที่ค้นหาและเลือกไว้ล่าสุดในแอป โดยไม่เปลี่ยนเส้นทางที่กำลังนำทาง"
        case .log: return "ล้าง log ที่แอปเก็บในเครื่อง บันทึกใหม่จะเกิดขึ้นตามการใช้งาน และไม่ลบสำเนาที่คุณเคยแชร์"
        case .history: return "ลบทริป การเติมน้ำมัน จุดจอด สถานที่ล่าสุด และ log ของทุกบัญชีในเครื่อง กู้คืนจากแอปไม่ได้ บัญชี การตั้งค่า และแคชยังคงอยู่"
        }
    }
}

struct DataManagementView: View {
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject var parking: ParkingSpotTracker
    @ObservedObject private var trips: TripRecorder
    @ObservedObject private var maps: DashMapProvider
    @ObservedObject private var navigator: DashNavigator
    @ObservedObject private var fuel = FuelLog.shared
    @State private var pendingRemoval: DataRemoval?
    @State private var isWorking = false
    @State private var status: String?
    @State private var error: String?
    @State private var exportDocument: HistoryDocument?
    @State private var showsExporter = false

    init(dashScreen: DashScreenService, parking: ParkingSpotTracker) {
        self.dashScreen = dashScreen
        self.parking = parking
        trips = dashScreen.trips
        maps = dashScreen.maps
        navigator = dashScreen.navigator
    }

    private var historyInUse: Bool { dashScreen.isRunning || trips.current != nil }
    private var cacheInUse: Bool {
        dashScreen.isRunning || navigator.isNavigating || maps.preparing != nil || maps.isSavingTiles || dashScreen.isMaintainingCache
    }

    var body: some View {
        List {
            if isWorking || status != nil {
                Section {
                    if isWorking {
                        HStack(spacing: 10) { ProgressView(); Text("กำลังจัดการข้อมูล…") }
                    } else if let status { Text(status).font(.subheadline) }
                }
            }

            Section {
                LabeledContent("ทริปที่บันทึก", value: "\(trips.trips.count)")
                LabeledContent("การเติมน้ำมัน", value: "\(fuel.fills.count)")
                Button("ส่งออกทริปและการเติมน้ำมัน") { exportHistory() }
                    .disabled(isWorking || (trips.trips.isEmpty && fuel.fills.isEmpty))
            } footer: {
                Text("ส่งออกประวัติที่บันทึกแล้วเป็นไฟล์ JSON ซึ่งมีพิกัดและเวลาเดินทาง ไม่รวมรหัสผ่านหรือเซสชัน การนำเข้าข้อมูลยังไม่รองรับ")
            }

            Section {
                removalButton(.cache, disabled: cacheInUse)
            } header: { Text("พื้นที่จัดเก็บ") } footer: {
                Text(cacheInUse ? "ปิดจอรถ จบการนำทาง และรอให้บันทึกแผนที่เสร็จก่อนล้างแคช" : "แคชจะถูกสร้างใหม่เมื่อเปิดภาพรถหรือใช้แผนที่")
            }

            Section {
                removalButton(.parking)
                removalButton(.recent)
                removalButton(.trips, disabled: historyInUse)
                removalButton(.fuel)
                removalButton(.log)
            } header: { Text("ประวัติในเครื่อง") } footer: {
                Text("ข้อมูลส่วนนี้ใช้ร่วมกันในแอปและอาจมาจากหลายบัญชี ลบทริปได้เมื่อปิดจอรถและหยุดบันทึกแล้ว")
            }

            Section {
                removalButton(.history, disabled: historyInUse)
            } footer: {
                Text("การลบประวัติไม่ใช่การลบบัญชี ZONTES และไม่ลบไฟล์ที่คุณส่งออกไว้")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("จัดการข้อมูล")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(pendingRemoval?.title ?? "ลบข้อมูล", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let removal = pendingRemoval {
                Button(removal.title, role: .destructive) { remove(removal) }
            }
            Button("ยกเลิก", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.detail ?? "")
        }
        .alert("ดำเนินการไม่สำเร็จ", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("ตกลง", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .fileExporter(isPresented: $showsExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "SmartAuto-history") { result in
            switch result {
            case .success: status = "ส่งออกประวัติแล้ว"
            case let .failure(failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
            exportDocument = nil
        }
    }

    private func removalButton(_ removal: DataRemoval, disabled: Bool = false) -> some View {
        Button(removal.title, role: .destructive) { pendingRemoval = removal }
            .disabled(isWorking || disabled)
    }

    private func exportHistory() {
        guard !isWorking else { return }
        isWorking = true
        status = nil
        let summaries = trips.trips
        let fills = fuel.fills
        Task {
            defer { isWorking = false }
            do {
                let data = try await Task.detached(priority: .utility) {
                    let exportedTrips = try summaries.map {
                        HistoryExport.Trip(summary: $0, points: try TripStore.pointsForExport($0.id))
                    }
                    return try HistoryExport(version: 1, exportedAt: Date(), trips: exportedTrips, fuel: fills).data()
                }.value
                exportDocument = HistoryDocument(data: data)
                showsExporter = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ removal: DataRemoval) {
        guard !isWorking else { return }
        // Recheck at confirmation: auto-connect may have started since the dialog opened.
        if (removal == .trips || removal == .history) && historyInUse {
            error = "ปิดจอรถและหยุดบันทึกทริปก่อนลบประวัติ"
            return
        }
        if removal == .cache && cacheInUse {
            error = "ปิดจอรถ จบการนำทาง และรอให้บันทึกแผนที่เสร็จก่อนล้างแคช"
            return
        }
        isWorking = true
        status = nil
        Task {
            defer { isWorking = false }
            do {
                switch removal {
                case .cache:
                    try await dashScreen.withCacheMaintenance {
                        maps.reset()
                        await VehicleArtworkStore.shared.clearCache()
                        await DashcamImageStore.shared.clearCache()
                        try await Task.detached(priority: .utility) { try AppDataFiles.clearMapCache() }.value
                    }
                case .parking: parking.clearSavedSpots()
                case .recent: dashScreen.navigator.clearRecents()
                case .trips: try trips.deleteAll()
                case .fuel: try fuel.deleteAll()
                case .log: try await EventLog.clearAndWait()
                case .history:
                    try trips.deleteAll()
                    try fuel.deleteAll()
                    parking.clearSavedSpots()
                    dashScreen.navigator.clearRecents()
                    try await EventLog.clearAndWait()
                }
                status = "\(removal.title)แล้ว"
            } catch {
                self.error = "ดำเนินการไม่ครบ บางข้อมูลอาจถูกลบแล้ว: \(error.localizedDescription)"
            }
        }
    }
}
