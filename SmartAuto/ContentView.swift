import Combine
import SwiftUI

private let groupDefaults = UserDefaults(suiteName: AppConstants.appGroup)

struct ContentView: View {
    @StateObject private var launcher = BroadcastLauncher()
    @State private var status = SharedStore.readStatus()
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
                Section {
                    StatusCard(status: status)
                    Button {
                        launcher.launch()
                    } label: {
                        Label(isLive ? "หยุด / เปลี่ยนการส่งภาพ" : "เริ่มส่งภาพขึ้นจอรถ",
                              systemImage: isLive ? "stop.circle.fill" : "play.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .background(BroadcastPickerHost(launcher: launcher).frame(width: 1, height: 1))
                } footer: {
                    Text("กดแล้วเลือก Smart Auto → Start Broadcast ภาพหน้าจอ iPhone จะถูกส่งขึ้นจอรถจนกว่าจะกดหยุด")
                }

                Section("วิธีใช้กับ CarPlay") {
                    StepRow(number: 1, text: "ตั้งค่า › Wi-Fi ต่อ iPhone กับ Wi-Fi ของรถ (ZT_…)")
                    StepRow(number: 2, text: "กด \"ทดสอบหาจอรถ\" ด้านล่าง ครั้งแรกให้กดอนุญาต Local Network")
                    StepRow(number: 3, text: "กด \"เริ่มส่งภาพขึ้นจอรถ\" แล้ว Start Broadcast")
                    StepRow(number: 4, text: "เปิด iCarCast › This iPhone แล้วหมุนเครื่องแนวนอน CarPlay จะขึ้นบนจอรถ")
                }

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
                }

                Section {
                    Picker("ตัวตนที่ส่งให้จอ", selection: $profileID) {
                        ForEach(DashProfile.all) { profile in
                            Text(profile.title).tag(profile.id)
                        }
                    }
                    Picker("คุณภาพภาพ", selection: $quality) {
                        ForEach(VideoQuality.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("กลับภาพ 180°", isOn: $flipPicture)
                    TextField("IP ของจอ (ว่าง = อัตโนมัติ)", text: $dashAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("ตั้งค่า")
                } footer: {
                    Text("\(DashProfile.byID(profileID).detail)\nเปลี่ยนค่าแล้วต้องหยุดและเริ่มส่งภาพใหม่จึงจะมีผล ถ้าภาพบนจอกลับหัวให้เปิด \"กลับภาพ 180°\"")
                }

                Section {
                    NavigationLink("ดู log") { LogView() }
                }
            }
            .navigationTitle("Smart Auto")
        }
        .onReceive(refresh) { _ in
            status = SharedStore.readStatus()
            wifiAddress = DashLocator.wifiAddressDescription()
        }
    }

    private var isLive: Bool {
        switch status.state {
        case .idle, .stopped, .failed: return false
        default: return Date().timeIntervalSince(status.updatedAt) < 5
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

private struct StatusCard: View {
    let status: BroadcastStatus

    var body: some View {
        let stale = status.state != .idle && status.state != .stopped
            && Date().timeIntervalSince(status.updatedAt) > 5
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(stale: stale))
                    .frame(width: 12, height: 12)
                Text(stale ? "ไม่ได้ส่งภาพ" : status.state.title)
                    .font(.title3.weight(.semibold))
            }
            if !stale, !status.message.isEmpty {
                Text(status.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !stale, status.state == .streaming || status.state == .waitingForDash {
                Text("\(status.width)×\(status.height) · \(status.fps) fps · ส่งแล้ว \(status.framesSent) เฟรม")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func color(stale: Bool) -> Color {
        if stale { return .gray }
        switch status.state {
        case .streaming: return .green
        case .waitingForDash, .connecting, .searching, .reconnecting: return .orange
        case .failed: return .red
        case .idle, .stopped: return .gray
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
