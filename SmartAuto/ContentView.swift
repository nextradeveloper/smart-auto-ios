import Foundation
import SwiftUI
import UIKit

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
    /// Owned here so the dash screen can show the bike's battery and lock from any tab.
    @StateObject private var bluetooth = VehicleBluetoothMonitor()
    @StateObject private var dashScreen = DashScreenService()

    var body: some View {
        TabView(selection: $selection) {
            VehicleDashboardView(bluetooth: bluetooth)
                .tabItem { TabIcon.vehicle; Text("Vehicle") }
                .tag(0)

            DashTabView(dashScreen: dashScreen)
                .tabItem { TabIcon.dash; Text("จอรถ") }
                .tag(1)

            ServiceView()
                .tabItem { TabIcon.service; Text("Service") }
                .tag(2)

            AccountView()
                .tabItem { TabIcon.account; Text("Account") }
                .tag(3)
        }
        .tint(.cyan)
        .onAppear {
            let monitor = bluetooth
            let screen = dashScreen
            monitor.onLinkChange = { [weak screen] up in screen?.bikeLink(up) }
            screen.startAutoConnect()
            if monitor.status.isPositive { screen.bikeLink(true) }
            dashScreen.vehicleSource = {
                DashScene.Vehicle(
                    connected: monitor.status.isPositive,
                    locked: monitor.isLocked,
                    voltage: monitor.batteryVoltage
                )
            }
        }
    }
}

/// Tab icons drawn into one small box, so wide symbols such as the motorcycle and the wrench
/// do not look bigger than the others.
private enum TabIcon {
    static let vehicle = make("motorcycle")
    static let dash = make("speedometer")
    static let service = make("wrench.and.screwdriver.fill")
    static let account = make("person.fill")

    private static func make(_ name: String) -> Image {
        let box = CGSize(width: 24, height: 18)
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration),
              symbol.size.width > 0, symbol.size.height > 0
        else { return Image(systemName: name) }
        let scale = min(box.width / symbol.size.width, box.height / symbol.size.height, 1)
        let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            symbol.withTintColor(.black).draw(in: CGRect(
                x: (box.width - size.width) / 2,
                y: (box.height - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
    }
}

private struct VehicleDashboardView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @ObservedObject var bluetooth: VehicleBluetoothMonitor
    @StateObject private var parking = ParkingSpotTracker()
    @State private var showsStylePicker = false
    @State private var showsFinder = false
    /// Seat or fuel lid that just opened; lit for a few seconds, as in the official app.
    @State private var justOpened: VehicleCommand?

    init(bluetooth: VehicleBluetoothMonitor) {
        self.bluetooth = bluetooth
    }

    private var isLocked: Bool? { bluetooth.isLocked ?? model.vehicle?.isLocked }
    private var batteryVoltage: Double? { bluetooth.batteryVoltage ?? model.vehicle?.batteryVoltage }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.05, green: 0.05, blue: 0.055), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // The page fits the screen instead of scrolling; the artwork gives up space first.
            VStack(spacing: 12) {
                header
                connectionStrip
                statusBar
                vehicleImage
                controlWheel
                searchButton
                lastUpdate
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.isBusy && model.vehicle == nil {
                ProgressView(model.busyText.isEmpty ? "กำลังดึงข้อมูลรถ…" : model.busyText)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(isPresented: $showsStylePicker) {
            VehicleStylePicker()
                .environmentObject(model)
        }
        .onAppear { configureBluetooth() }
        .onChange(of: model.vehicle?.carCode) { _ in configureBluetooth() }
        .onChange(of: model.vehicle?.mcuID) { _ in configureBluetooth() }
    }

    private func configureBluetooth() {
        let pke = model.vehicle?.carCode ?? ""
        parking.configure(pke: pke)
        let tracker = parking
        bluetooth.onEvent = { event in tracker.handle(event) }
        bluetooth.configure(pke: pke, mcu: model.vehicle?.mcuID ?? "")
    }

    private func run(_ command: VehicleCommand) {
        Task {
            do {
                try await bluetooth.send(command)
                guard command == .seat || command == .fuelLid else { return }
                justOpened = command
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if justOpened == command { justOpened = nil }
            } catch {
                model.message = error.localizedDescription
            }
        }
    }

    private func refreshAll() {
        if bluetooth.status.isPositive {
            bluetooth.readBattery()
        } else {
            bluetooth.refresh()
        }
        Task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.vehicleTitle.uppercased())
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle = model.vehicleSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RoundIconButton(systemImage: "arrow.clockwise", label: "รีเฟรช", isWorking: model.isBusy) {
                refreshAll()
            }
            RoundIconButton(systemImage: "bell", label: "การแจ้งเตือน") {
                model.message = "ยังไม่มีการแจ้งเตือนใหม่"
            }
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
            Spacer(minLength: 0)
            Label {
                Text(batteryVoltage.map { String(format: "%.1f V", $0) } ?? "--")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            } icon: {
                Image(systemName: batterySymbol)
                    .foregroundStyle(batteryColor)
            }
            .accessibilityLabel("แบตเตอรี่")
            Spacer(minLength: 0)
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

    /// Rough 12 V battery charge from the resting voltage; charging reads as full.
    private var batterySymbol: String {
        guard let volts = batteryVoltage else { return "battery.0" }
        if volts >= 12.6 { return "battery.100" }
        if volts >= 12.4 { return "battery.75" }
        if volts >= 12.2 { return "battery.50" }
        if volts >= 12.0 { return "battery.25" }
        return "battery.0"
    }

    private var batteryColor: Color {
        guard let volts = batteryVoltage else { return .secondary }
        if volts >= 12.4 { return .green }
        if volts >= 12.0 { return .orange }
        return .red
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
        .frame(minHeight: 110, maxHeight: 235)
        .layoutPriority(-1)
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
            .padding(36)
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

            Group {
                WheelButton(title: "Fuel", systemImage: "fuelpump.fill",
                            isActive: justOpened == .fuelLid,
                            isWorking: bluetooth.commandInProgress == .fuelLid) { run(.fuelLid) }
                    .offset(y: -82)

                WheelButton(title: "Lock", systemImage: "lock.fill",
                            isActive: isLocked == true,
                            isWorking: bluetooth.commandInProgress == .lock) { run(.lock) }
                    .offset(x: -82)

                WheelButton(title: "Unlock", systemImage: "lock.open.fill",
                            isActive: isLocked == false,
                            isWorking: bluetooth.commandInProgress == .unlock) { run(.unlock) }
                    .offset(x: 82)

                WheelButton(title: "Seat", systemImage: VehicleCommand.seat.systemImage,
                            isActive: justOpened == .seat,
                            isWorking: bluetooth.commandInProgress == .seat) { run(.seat) }
                    .offset(y: 82)
            }
            .disabled(!bluetooth.status.isPositive || bluetooth.commandInProgress != nil)

            Image(systemName: bluetooth.status.isPositive ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(bluetooth.status.isPositive ? Color.cyan : Color.secondary)
                .shadow(color: bluetooth.status.isPositive ? Color.cyan.opacity(0.7) : Color.clear, radius: 8)
                .frame(width: 68, height: 68)
                .background(.black, in: Circle())
                .overlay {
                    Circle().stroke(bluetooth.status.isPositive ? Color.cyan.opacity(0.45) : Color.white.opacity(0.12))
                }
                .accessibilityLabel(bluetooth.status.isPositive ? "เชื่อมต่อ Bluetooth แล้ว" : "ยังไม่เชื่อมต่อ Bluetooth")
        }
        .frame(width: 252, height: 252)
    }

    private var wheelDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(width: 1, height: 236)
    }

    /// Thai vehicles have no 4G module, so this opens the phone-side finder instead of the
    /// remote find command.
    private var searchButton: some View {
        Button { showsFinder = true } label: {
            HStack(spacing: 8) {
                Image(systemName: VehicleCommand.find.systemImage)
                Text(VehicleCommand.find.title)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsFinder) {
            FindVehicleView(bluetooth: bluetooth, parking: parking, vehicleName: model.vehicleTitle)
        }
    }

    @ViewBuilder
    private var lastUpdate: some View {
        if let updated = model.vehicle?.updatedAt, !updated.isEmpty {
            Text("อัปเดตล่าสุด \(updated)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RoundIconButton: View {
    let systemImage: String
    let label: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage).font(.title3)
                }
            }
            .frame(width: 42, height: 42)
            .background(.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(label)
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
    var isActive = false
    var isWorking = false
    let action: () -> Void
    @Environment(\.isEnabled) var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if isWorking {
                    ProgressView().tint(.cyan)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isActive ? Color.cyan : Color.white)
                }
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 64, height: 52)
            .contentShape(Rectangle())
            .opacity(isEnabled || isWorking ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// The dash tab, in order of what matters on a ride: the dash as it is now (tap for the full-screen
/// map), whether it is on, where to go, then a few settings. Few words.
private struct DashTabView: View {
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject private var navigator: DashNavigator
    @ObservedObject private var maps: DashMapProvider
    @StateObject private var launcher = BroadcastLauncher()
    @State private var showsSearch = false
    @State private var showsAddStop = false
    @State private var showsMap = false
    @State private var previewing: DashDestination?
    @AppStorage(DashSettings.themeKey) private var theme = DashSettings.Theme.dark.rawValue
    @AppStorage(DashSettings.avoidHighwaysKey) private var avoidHighways = false
    @AppStorage(DashSettings.avoidTollsKey) private var avoidTolls = true
    @AppStorage(DashSettings.threeDKey) private var threeD = true
    @AppStorage(DashSettings.autoConnectKey) private var autoConnect = true
    @AppStorage(DashSettings.voiceKey) private var voice = true
    @AppStorage(DashSettings.mapOnRightKey) private var mapOnRight = false

    init(dashScreen: DashScreenService) {
        self.dashScreen = dashScreen
        navigator = dashScreen.navigator
        maps = dashScreen.maps
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showsMap = true } label: { screenPreview }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                    statusRow
                    Toggle("เปิดจออัตโนมัติ", isOn: $autoConnect)
                        .onChange(of: autoConnect) { _ in dashScreen.autoConnectChanged() }
                }

                Section {
                    if navigator.isNavigating {
                        DashGuidanceBanner(navigator: navigator)
                            .padding(.vertical, 6)
                        if let preparing = maps.preparing {
                            ProgressView(value: Double(preparing.done), total: Double(max(preparing.total, 1))) {
                                Text("แผนที่ \(preparing.done)/\(preparing.total)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let next = navigator.stops.first {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("จุดแวะถัดไป")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(next.name)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button("ข้าม") { navigator.skipStop() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        Button { showsAddStop = true } label: {
                            Label("เพิ่มจุดแวะ", systemImage: "plus.circle.fill")
                        }
                        Button("จบการนำทาง", role: .destructive) { dashScreen.stopNavigation() }
                    } else {
                        Button { showsSearch = true } label: { searchField }
                            .buttonStyle(.plain)
                        ForEach(Array(navigator.recents.prefix(3))) { place in
                            Button { previewing = place } label: { RecentPlaceRow(place: place) }
                        }
                    }
                }

                Section {
                    Toggle("เสียงนำทาง", isOn: $voice)
                    Toggle("เลี่ยงทางด่วน/มอเตอร์เวย์", isOn: $avoidTolls)
                    Toggle("เลี่ยงทางหลวง", isOn: $avoidHighways)
                    Picker("ธีม", selection: $theme) {
                        ForEach(DashSettings.Theme.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("มุมมอง", selection: $threeD) {
                        Text("2D").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("แผนที่", selection: $mapOnRight) {
                        Text("แผนที่ซ้าย").tag(false)
                        Text("แผนที่ขวา").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        launcher.launch()
                    } label: {
                        Label("แชร์หน้าจอ", systemImage: "rectangle.on.rectangle")
                    }
                    .disabled(dashScreen.isRunning)
                    .background(BroadcastPickerHost(launcher: launcher).frame(width: 1, height: 1))

                    NavigationLink {
                        DashcamView()
                    } label: {
                        Label("กล้องรถ", systemImage: "video")
                    }

                    NavigationLink {
                        LegacyToolsView()
                    } label: {
                        Label("ตั้งค่าจอและ log", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("จอรถ")
            .sheet(isPresented: $showsSearch) {
                DashDestinationSearch(dashScreen: dashScreen, navigator: navigator)
            }
            .sheet(isPresented: $showsAddStop) {
                DashDestinationSearch(dashScreen: dashScreen, navigator: navigator) { place in
                    navigator.addStop(place)
                }
            }
            .sheet(item: $previewing) { place in
                NavigationStack {
                    DashRoutePreview(destination: place, dashScreen: dashScreen) { previewing = nil }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("ปิด") { previewing = nil }
                            }
                        }
                }
            }
            .fullScreenCover(isPresented: $showsMap) {
                DashMapScreen(dashScreen: dashScreen, navigator: navigator)
            }
            .onAppear { dashScreen.previewEnabled = true }
            .onDisappear { dashScreen.previewEnabled = false }
        }
    }

    /// The dash as it is now, at its own shape (1280x528). Tap for the full-screen map.
    private var screenPreview: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(white: 0.07)
                if dashScreen.isRunning, let preview = dashScreen.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Image(systemName: "speedometer")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
                .padding(10)
        }
        .aspectRatio(1280.0 / 528.0, contentMode: .fit)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Button(dashScreen.isRunning ? "ปิด" : "เปิดจอ") {
                dashScreen.isRunning ? dashScreen.stop() : dashScreen.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(dashScreen.isRunning ? .red : .accentColor)
            .controlSize(.small)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
            Text("ค้นหาสถานที่")
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private var statusText: String {
        guard dashScreen.isRunning else { return "ปิดอยู่" }
        switch dashScreen.state {
        case .streaming: return "แสดงบนจอรถ"
        case .reconnecting, .failed: return "ต่อ Wi-Fi รถไม่ได้"
        default: return "กำลังเชื่อมต่อ"
        }
    }

    private var statusColor: Color {
        guard dashScreen.isRunning else { return .secondary }
        switch dashScreen.state {
        case .streaming: return .green
        case .reconnecting, .failed: return .red
        default: return .orange
        }
    }
}

private struct RecentPlaceRow: View {
    let place: DashDestination

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(place.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
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
    @AppStorage("profileID", store: groupDefaults) private var profileID = DashProfile.zontesH.id
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
                    LabeledContent("ชื่อรถ", value: model.vehicle == nil ? "--" : model.vehicleTitle)
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
