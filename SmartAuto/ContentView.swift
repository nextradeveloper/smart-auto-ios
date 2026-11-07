import Foundation
import SwiftUI

private let groupDefaults = UserDefaults(suiteName: AppConstants.appGroup)

struct ContentView: View {
    @StateObject private var model = ZontesAppModel()

    var body: some View {
        Group {
            if model.session == nil {
                LoginView()
            } else {
                MainShellView()
            }
        }
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .alert(
            "Smart Auto",
            isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )
        ) {
            Button("ตกลง", role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @State private var account = ""
    @State private var password = ""
    @State private var acceptsTerms = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.06, green: 0.07, blue: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 54)
                    VStack(spacing: 8) {
                        Text("ZONTES")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .tracking(7)
                        Text("SMART AUTO")
                            .font(.caption.weight(.semibold))
                            .tracking(4)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        Text("เชื่อมต่อรถของคุณ")
                            .font(.title2.bold())
                        Text("ใช้บัญชีอีเมลและรหัสผ่านเดียวกับ ZONTES Smart")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        DarkField(title: "อีเมล", systemImage: "envelope.fill") {
                            TextField("name@example.com", text: $account)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                        }
                        DarkField(title: "รหัสผ่าน", systemImage: "lock.fill") {
                            SecureField("รหัสผ่าน ZONTES Smart", text: $password)
                                .textContentType(.password)
                        }

                        Button {
                            acceptsTerms.toggle()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: acceptsTerms ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(acceptsTerms ? Color.cyan : .secondary)
                                Text("ฉันยอมรับนโยบายความเป็นส่วนตัวของ ZONTES และอนุญาตให้แอปดึงข้อมูลรถของบัญชีนี้")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await model.login(account: account, password: password) }
                        } label: {
                            HStack {
                                if model.isBusy { ProgressView().tint(.black) }
                                Text(model.isBusy ? (model.busyText.isEmpty ? "กำลังเชื่อมต่อ…" : model.busyText) : "เข้าสู่ระบบ")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .disabled(!acceptsTerms || account.isEmpty || password.isEmpty || model.isBusy)
                    }
                    .padding(22)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.08))
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

private struct DarkField<Field: View>: View {
    let title: String
    let systemImage: String
    let field: Field

    init(title: String, systemImage: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.systemImage = systemImage
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.cyan)
                    .frame(width: 20)
                field
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 52)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct MainShellView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            VehicleDashboardView()
                .tabItem { Label("VEHICLE", systemImage: "motorcycle") }
                .tag(0)

            CarPlayView()
                .tabItem { Label("CARPLAY", systemImage: "car.side.fill") }
                .tag(1)

            ServiceView()
                .tabItem { Label("SERVICE", systemImage: "wrench.and.screwdriver.fill") }
                .tag(2)

            AccountView()
                .tabItem { Label("MY ACCOUNT", systemImage: "person.fill") }
                .tag(3)
        }
        .tint(.cyan)
    }
}

private struct VehicleDashboardView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @StateObject private var bluetooth = VehicleBluetoothMonitor()
    @State private var pendingCommand: VehicleCommand?
    @State private var asksBluetoothPassword = false
    @State private var bluetoothPassword = ""
    @State private var showsStylePicker = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.05, green: 0.05, blue: 0.055), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    header
                    connectionStrip
                    statusBar
                    vehicleImage
                    controlWheel
                    HStack(spacing: 12) {
                        bluetoothAction(.seat)
                        bluetoothAction(.fuelLid)
                    }
                    pageDots
                    lastUpdate
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
            .refreshable { await model.refresh() }
            .alert("รหัส Bluetooth ของรถ", isPresented: $asksBluetoothPassword) {
                SecureField("รหัส 6 หลัก", text: $bluetoothPassword)
                    .keyboardType(.numberPad)
                Button("ตรวจสอบ") { checkBluetoothPassword() }
                Button("ยกเลิก", role: .cancel) { bluetoothPassword = "" }
            } message: {
                Text("รถไม่รับรหัส Bluetooth ที่แอปใช้อยู่ กรอกรหัส 6 หลักที่ตั้งไว้ตอนผูกรถในแอป ZONTES Smart")
            }
            .sheet(isPresented: $showsStylePicker) {
                VehicleStylePicker()
                    .environmentObject(model)
            }

            if model.isBusy && model.vehicle == nil {
                ProgressView(model.busyText.isEmpty ? "กำลังดึงข้อมูลรถ…" : model.busyText)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(item: $pendingCommand) { command in
            Alert(
                title: Text(command.title),
                message: Text("ยืนยันส่งคำสั่งนี้ไปยังรถ \(model.vehicle?.displayName ?? "")"),
                primaryButton: .destructive(Text("ยืนยัน")) {
                    Task {
                        if command == .find {
                            await model.send(command)
                        } else {
                            do {
                                try await bluetooth.send(command)
                                model.message = "รถตอบรับคำสั่ง “\(command.title)” ผ่าน Bluetooth แล้ว"
                            } catch ZontesError.bluetoothPasswordRejected {
                                bluetoothPassword = ""
                                asksBluetoothPassword = true
                            } catch { model.message = error.localizedDescription }
                        }
                    }
                },
                secondaryButton: .cancel(Text("ยกเลิก"))
            )
        }
        .onAppear { configureBluetooth() }
        .onChange(of: model.vehicle?.carCode) { _ in configureBluetooth() }
        .onChange(of: model.vehicle?.mcuID) { _ in configureBluetooth() }
    }

    private func configureBluetooth() {
        bluetooth.configure(pke: model.vehicle?.carCode ?? "", mcu: model.vehicle?.mcuID ?? "")
    }

    private func checkBluetoothPassword() {
        let candidate = bluetoothPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        bluetoothPassword = ""
        Task {
            do {
                try await bluetooth.verifyPassword(candidate)
                model.message = "รหัส Bluetooth ถูกต้องและบันทึกแล้ว กดสั่งงานรถอีกครั้งได้เลย"
            } catch ZontesError.bluetoothPasswordRejected {
                model.message = "รหัส Bluetooth ไม่ถูกต้อง กดสั่งงานอีกครั้งเพื่อกรอกรหัสใหม่"
            } catch {
                model.message = error.localizedDescription
            }
        }
    }

    private func bluetoothAction(_ command: VehicleCommand) -> some View {
        Button { pendingCommand = command } label: {
            Label(command.title, systemImage: command.systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!bluetooth.status.isPositive || bluetooth.isBusy)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.vehicle?.displayName.uppercased() ?? "ZONTES")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(2)
                Text(model.vehicle?.carCode.isEmpty == false ? model.vehicle?.carCode ?? "" : "รถของคุณ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.message = "ยังไม่มีการแจ้งเตือนใหม่"
            } label: {
                Image(systemName: "bell")
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionStrip: some View {
        HStack(spacing: 8) {
            ConnectionBadge(
                title: "ระบบรถ",
                value: model.vehicle?.isOnline == true ? "ออนไลน์" : "ออฟไลน์",
                symbol: "network",
                isPositive: model.vehicle?.isOnline == true
            )

            Button { bluetooth.refresh() } label: {
                ConnectionBadge(
                    title: "Bluetooth",
                    value: bluetooth.status.title,
                    symbol: bluetooth.status.symbol,
                    isPositive: bluetooth.status.isPositive
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(model.vehicle?.fuelPercent.map { "\($0)%" } ?? "--")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            } icon: {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(.cyan)
            }
            Spacer()
            Rectangle()
                .fill(.red)
                .frame(width: 26, height: 2)
            Text(model.vehicle?.rangeKilometers.map(String.init) ?? "--")
                .font(.subheadline.monospacedDigit().weight(.bold))
            Text("km")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var vehicleImage: some View {
        ZStack {
            Ellipse()
                .fill(.cyan.opacity(0.08))
                .frame(width: 270, height: 54)
                .blur(radius: 18)
                .offset(y: 70)

            if let url = model.vehicleImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
                    case .failure:
                        vehiclePlaceholder
                    default:
                        ProgressView().tint(.white)
                    }
                }
            } else {
                vehiclePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 235)
        .contentShape(Rectangle())
        .onTapGesture { showsStylePicker = true }
        .overlay(alignment: .bottomTrailing) {
            Button { showsStylePicker = true } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("เลือกรุ่นและสีรถ")
        }
    }

    private var vehiclePlaceholder: some View {
        Image(systemName: "motorcycle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white.opacity(0.28))
            .padding(48)
    }

    private var controlWheel: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.045), .black.opacity(0.8)],
                        center: .center,
                        startRadius: 18,
                        endRadius: 126
                    )
                )
                .overlay { Circle().stroke(.white.opacity(0.08)) }

            wheelDivider.rotationEffect(.degrees(45))
            wheelDivider.rotationEffect(.degrees(-45))

            WheelButton(title: "Search", systemImage: "location.fill", isWorking: model.commandInProgress == .find) {
                pendingCommand = .find
            }
            .offset(y: -82)

            WheelButton(title: "Lock", systemImage: "lock.fill", accent: .cyan, isWorking: bluetooth.commandInProgress == .lock) {
                pendingCommand = .lock
            }
            .disabled(!bluetooth.status.isPositive)
            .offset(x: -82)

            WheelButton(title: "Unlock", systemImage: "lock.open.fill", isWorking: bluetooth.commandInProgress == .unlock) {
                pendingCommand = .unlock
            }
            .disabled(!bluetooth.status.isPositive)
            .offset(x: 82)

            WheelButton(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .offset(y: 82)

            VStack(spacing: 3) {
                Image(systemName: model.vehicle?.isOnline == true ? "bolt.fill" : "bolt.slash.fill")
                    .foregroundStyle(model.vehicle?.isOnline == true ? Color.cyan : Color.secondary)
                Text("ZONTES")
                    .font(.caption2.weight(.black))
                    .tracking(1)
            }
            .frame(width: 68, height: 68)
            .background(.black, in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.12)) }
        }
        .frame(width: 252, height: 252)
        .disabled(model.commandInProgress != nil || bluetooth.isBusy)
    }

    private var wheelDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(width: 1, height: 236)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 5, height: 5)
            Circle().fill(.white.opacity(0.25)).frame(width: 5, height: 5)
        }
        .padding(.top, 4)
    }

    private var lastUpdate: some View {
        Text(model.vehicle?.updatedAt.isEmpty == false ? "อัปเดตล่าสุด \(model.vehicle?.updatedAt ?? "")" : "ดึงลงเพื่อรีเฟรชข้อมูล")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The official app shows the model and colour chosen while binding, which only that phone
/// knows; this lets the owner pick the same artwork from the same catalog.
private struct VehicleStylePicker: View {
    @EnvironmentObject private var model: ZontesAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.motorCatalog.isEmpty {
                    VStack(spacing: 14) {
                        if let loadError {
                            Text(loadError)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("ลองอีกครั้ง") { Task { await load() } }
                        } else {
                            ProgressView("กำลังโหลดรุ่นรถ…")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button {
                                model.selectStyle(nil)
                                dismiss()
                            } label: {
                                HStack {
                                    Text("ใช้ภาพจากบัญชี ZONTES")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if model.selectedStyle == nil {
                                        Image(systemName: "checkmark").foregroundStyle(.cyan)
                                    }
                                }
                            }
                        } footer: {
                            Text("เลือกรุ่นและสีให้ตรงกับที่เลือกไว้ตอนผูกรถในแอป ZONTES Smart")
                        }

                        ForEach(orderedCategories) { category in
                            Section(category.name) {
                                ForEach(category.styles) { style in
                                    Button {
                                        model.selectStyle(style)
                                        dismiss()
                                    } label: {
                                        styleRow(style)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .scrollContentBackground(.hidden)
            .navigationTitle("รุ่นและสีรถ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ปิด") { dismiss() }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    /// The family whose artwork the account already uses comes first.
    private var orderedCategories: [MotorCategory] {
        var categories = model.motorCatalog
        let current = model.vehicle?.imageURL?.lastPathComponent
        if let current, let index = categories.firstIndex(where: { category in
            category.styles.contains { $0.imageURL.lastPathComponent == current }
        }) {
            let match = categories.remove(at: index)
            categories.insert(match, at: 0)
        }
        return categories
    }

    private func styleRow(_ style: MotorStyle) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: style.thumbnailURL ?? style.imageURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.white.opacity(0.05)
            }
            .frame(width: 76, height: 58)

            Text(style.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if model.selectedStyle?.id == style.id {
                Image(systemName: "checkmark").foregroundStyle(.cyan)
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            try await model.loadMotorCatalog()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ConnectionBadge: View {
    let title: String
    let value: String
    let symbol: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPositive ? Color.green : Color.secondary)
                .frame(width: 26, height: 26)
                .background((isPositive ? Color.green : Color.white).opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct WheelButton: View {
    let title: String
    let systemImage: String
    var accent: Color = .white
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if isWorking {
                    ProgressView().tint(accent)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 64, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CarPlayView: View {
    @StateObject private var direct = CarPlayDirect()
    @StateObject private var launcher = BroadcastLauncher()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.cyan)
                        Text("CarPlay บนหน้าจอรถ")
                            .font(.title2.bold())
                        Text("เชื่อมต่อ Wi-Fi ของรถก่อน แล้วเลือกวิธีส่งภาพที่เหมาะกับหน้าจอของคุณ")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Button {
                        direct.isRunning ? direct.stop() : direct.start()
                    } label: {
                        Label(direct.isRunning ? "หยุดส่ง CarPlay" : "ส่ง CarPlay ขึ้นจอรถ", systemImage: direct.isRunning ? "stop.circle.fill" : "car.fill")
                    }
                    if !direct.message.isEmpty {
                        Text(direct.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("CarPlay โดยตรง")
                } footer: {
                    Text("เปิด iCarCast โหมด This iPhone ค้างไว้ แล้วกลับมากดเริ่มส่ง CarPlay")
                }

                Section("สำรอง: แชร์หน้าจอ") {
                    Button {
                        launcher.launch()
                    } label: {
                        Label("แชร์หน้าจอ iPhone", systemImage: "rectangle.on.rectangle")
                    }
                    .background(BroadcastPickerHost(launcher: launcher).frame(width: 1, height: 1))

                    NavigationLink("การตั้งค่าจอและ log") {
                        LegacyToolsView()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("CarPlay")
        }
    }
}

private struct ServiceView: View {
    @EnvironmentObject private var model: ZontesAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("ข้อมูลรถ") {
                    MetricRow(title: "แบตเตอรี่", value: model.vehicle?.batteryVoltage.map { String(format: "%.1f V", $0) } ?? "--")
                    MetricRow(title: "ลมยางหน้า", value: model.vehicle?.frontTireKPa.map { "\($0) kPa" } ?? "--")
                    MetricRow(title: "ลมยางหลัง", value: model.vehicle?.rearTireKPa.map { "\($0) kPa" } ?? "--")
                    MetricRow(title: "ระยะถึงเช็กระยะ", value: model.vehicle?.maintenanceKilometers.map { "\($0) km" } ?? "--")
                    MetricRow(title: "ดาวเทียม", value: model.vehicle?.satelliteCount.map(String.init) ?? "--")
                }

                Section {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("รีเฟรชข้อมูลรถ", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Service")
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title, value: value)
    }
}

private struct LegacyToolsView: View {
    @State private var probeRunning = false
    @State private var probeResult: String?
    @AppStorage("profileID", store: groupDefaults) private var profileID = DashProfile.zontesG.id
    @AppStorage("quality", store: groupDefaults) private var quality: VideoQuality = .normal
    @AppStorage("flipPicture", store: groupDefaults) private var flipPicture = false
    @AppStorage("dashAddressOverride", store: groupDefaults) private var dashAddress = ""

    var body: some View {
        List {
            Section("การเชื่อมต่อ") {
                LabeledContent("Wi-Fi ของ iPhone", value: DashLocator.wifiAddressDescription())
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
                Text("ต่อ Wi-Fi ของรถ (ZT_…) ก่อนใช้งานการส่งภาพขึ้นหน้าจอ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("ตั้งค่าจอ") {
                Picker("ตัวตนที่ส่งให้จอ", selection: $profileID) {
                    ForEach(DashProfile.all) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }
                TextField("IP ของจอ (ว่าง = อัตโนมัติ)", text: $dashAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("คุณภาพภาพ", selection: $quality) {
                    ForEach(VideoQuality.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("กลับภาพ 180°", isOn: $flipPicture)
            }

            Section {
                NavigationLink("ดู log") { LogView() }
            }
        }
        .navigationTitle("เครื่องมือจอรถ")
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

private struct AccountView: View {
    @EnvironmentObject private var model: ZontesAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.session?.account ?? "")
                                .font(.headline)
                            Text("ZONTES Smart account")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("รถที่เชื่อมต่อ") {
                    LabeledContent("ชื่อรถ", value: model.vehicle?.displayName ?? "--")
                    LabeledContent("PKE Code", value: masked(model.vehicle?.carCode ?? model.session?.carCode ?? ""))
                    LabeledContent("สิทธิ์", value: model.session?.isOwner == true ? "เจ้าของรถ" : "ผู้ได้รับอนุญาต")
                }

                Section {
                    Button("ออกจากระบบ", role: .destructive) { model.logout() }
                } footer: {
                    Text("รหัสผ่านไม่ถูกบันทึกในแอป ส่วน session ถูกเก็บใน iOS Keychain และจะถูกลบเมื่อออกจากระบบ")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("My Account")
        }
    }

    private func masked(_ value: String) -> String {
        guard value.count > 6 else { return value.isEmpty ? "--" : value }
        return String(value.prefix(3)) + "••••" + String(value.suffix(3))
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
