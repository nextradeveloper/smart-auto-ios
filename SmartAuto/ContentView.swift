import Combine
import SwiftUI

private let groupDefaults = UserDefaults(suiteName: AppConstants.appGroup)

struct ContentView: View {
    @StateObject private var direct = CarPlayDirect()
    @StateObject private var launcher = BroadcastLauncher()
    @State private var broadcastStatus = SharedStore.readStatus()
    @State private var probeRunning = false
    @State private var probeResult: String?
    @State private var wifiAddress = DashLocator.wifiAddressDescription()

    @AppStorage("profileID", store: groupDefaults) private var profileID = DashProfile.zontesG.id
    @AppStorage("quality", store: groupDefaults) private var quality: VideoQuality = .normal
    @AppStorage("flipPicture", store: groupDefaults) private var flipPicture = false
    @AppStorage("dashAddressOverride", store: groupDefaults) private var dashAddress = ""

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                directSection
                stepsSection
                connectionSection
                settingsSection
                broadcastSection
                Section {
                    NavigationLink("ดู log") { LogView() }
                }
            }
            .navigationTitle("Smart Auto")
        }
        .onReceive(refresh) { _ in
            broadcastStatus = SharedStore.readStatus()
            wifiAddress = DashLocator.wifiAddressDescription()
        }
    }

    // MARK: CarPlay direct

    private var directSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(color(for: direct.state))
                        .frame(width: 12, height: 12)
                    Text(direct.state.title)
                        .font(.title3.weight(.semibold))
                }
                if !direct.message.isEmpty {
                    Text(direct.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if direct.isRunning {
                    Text("CarPlay \(direct.carPlayConnected ? "เชื่อมต่อแล้ว" : "ยังไม่เชื่อมต่อ")"
                         + (direct.streamSize.isEmpty ? "" : " · \(direct.streamSize)")
                         + " · ส่งแล้ว \(direct.framesSent) เฟรม")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

            Button {
                if direct.isRunning { direct.stop() } else { direct.start() }
            } label: {
                Label(direct.isRunning ? "หยุดส่ง CarPlay" : "ส่ง CarPlay ขึ้นจอรถ",
                      systemImage: direct.isRunning ? "stop.circle.fill" : "car.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(direct.isRunning ? .red : .accentColor)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("CarPlay โดยตรง (ไม่แชร์จอ)")
        } footer: {
            Text("กดแล้วสลับกลับไปที่ iCarCast เปิดค้างไว้และอย่าล็อกจอ Smart Auto จะทำงานอยู่เบื้องหลัง (มีไอคอนตำแหน่งสีน้ำเงิน)")
        }
    }

    private var stepsSection: some View {
        Section("วิธีใช้") {
            StepRow(number: 1, text: "ตั้งค่า › Wi-Fi ต่อ iPhone กับ Wi-Fi ของรถ (ZT_…)")
            StepRow(number: 2, text: "iCarCast › Settings: Resolution = 1920 × 720 และเปิด Browser screen (ทำครั้งเดียว)")
            StepRow(number: 3, text: "เปิด iCarCast › This iPhone รอจน CarPlay ขึ้น")
            StepRow(number: 4, text: "สลับมา Smart Auto กด \"ส่ง CarPlay ขึ้นจอรถ\" แล้วสลับกลับไป iCarCast ทิ้งไว้")
            StepRow(number: 5, text: "ปิดล็อกจออัตโนมัติขณะขี่ (ตั้งค่า › จอภาพ › ล็อกอัตโนมัติ › ไม่ใช้)")
        }
    }

    // MARK: Connection test

    private var connectionSection: some View {
        Section {
            LabeledContent("Wi-Fi ของ iPhone", value: wifiAddress)
            Button {
                runProbe()
            } label: {
                HStack {
                    Text("ทดสอบหาจอรถ")
                    if probeRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(probeRunning)
            if let probeResult {
                Text(probeResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("การเชื่อมต่อ")
        } footer: {
            Text("ครั้งแรกให้กดอนุญาต Local Network ไม่อย่างนั้นแอปจะคุยกับจอรถไม่ได้")
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Picker("ตัวตนที่ส่งให้จอ", selection: $profileID) {
                ForEach(DashProfile.all) { profile in
                    Text(profile.title).tag(profile.id)
                }
            }
            TextField("IP ของจอ (ว่าง = อัตโนมัติ)", text: $dashAddress)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("ตั้งค่า")
        } footer: {
            Text("\(DashProfile.byID(profileID).detail)\nเปลี่ยนค่าแล้วต้องหยุดและเริ่มส่งใหม่จึงจะมีผล")
        }
    }

    // MARK: Screen broadcast (fallback)

    private var broadcastSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(broadcastLive ? color(for: broadcastStatus.state) : .gray)
                    .frame(width: 10, height: 10)
                Text(broadcastLive ? broadcastStatus.state.title : "ไม่ได้ใช้")
                    .font(.subheadline)
            }
            Button {
                launcher.launch()
            } label: {
                Label(broadcastLive ? "หยุด / เปลี่ยนการแชร์จอ" : "แชร์ทั้งจอ iPhone ขึ้นจอรถ",
                      systemImage: "rectangle.on.rectangle")
            }
            .background(BroadcastPickerHost(launcher: launcher).frame(width: 1, height: 1))
            Picker("คุณภาพภาพ", selection: $quality) {
                ForEach(VideoQuality.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Toggle("กลับภาพ 180°", isOn: $flipPicture)
        } header: {
            Text("สำรอง: แชร์จอ")
        } footer: {
            Text("ใช้เมื่อโหมด CarPlay โดยตรงใช้กับจอรถไม่ได้ ภาพทั้งหน้าจอ iPhone จะขึ้นจอรถ กดแล้วเลือก Smart Auto › Start Broadcast")
        }
    }

    private var broadcastLive: Bool {
        switch broadcastStatus.state {
        case .idle, .stopped, .failed: return false
        default: return Date().timeIntervalSince(broadcastStatus.updatedAt) < 5
        }
    }

    private func color(for state: BroadcastState) -> Color {
        switch state {
        case .streaming: return .green
        case .waitingForDash, .connecting, .searching, .reconnecting: return .orange
        case .failed: return .red
        case .idle, .stopped: return .gray
        }
    }

    private func runProbe() {
        probeRunning = true
        probeResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DashLocator.locate(log: { line in
                EventLog.record("APP", line)
            })
            let text: String
            switch result {
            case let .success(endpoint):
                text = "พบจอที่ \(endpoint.host) (ตอบรับเป็น \(endpoint.probePackage)) พร้อมส่งภาพ"
            case let .failure(failure):
                text = failure.description
            }
            DispatchQueue.main.async {
                probeResult = text
                probeRunning = false
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

struct LogView: View {
    @State private var text = EventLog.read()

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "ยังไม่มี log" : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("ล้าง") {
                    EventLog.clear()
                    text = ""
                }
                ShareLink(item: SharedStore.logURL)
                Button {
                    text = EventLog.read()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}
