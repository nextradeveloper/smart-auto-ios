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

private struct MainShellView: View {
    @EnvironmentObject private var model: ZontesAppModel
    @State private var selection = 0
    /// Owned here so the dash screen can show the bike's battery and lock from any tab.
    @StateObject private var bluetooth = VehicleBluetoothMonitor()
    @StateObject private var dashScreen = DashScreenService()
    @StateObject private var parking = ParkingSpotTracker()

    var body: some View {
        TabView(selection: $selection) {
            VehicleDashboardView(bluetooth: bluetooth, parking: parking)
                .tabItem { TabIcon.vehicle; Text("รถ") }
                .tag(0)

            DashTabView(dashScreen: dashScreen)
                .tabItem { TabIcon.dash; Text("จอรถ") }
                .tag(1)

            ServiceView(trips: dashScreen.trips)
                .tabItem { TabIcon.service; Text("ดูแลรถ") }
                .tag(2)

            AccountView(bluetooth: bluetooth, dashScreen: dashScreen, parking: parking)
                .tabItem { TabIcon.account; Text("บัญชี") }
                .tag(3)
        }
        .tint(AppTheme.accent)
        .onAppear {
            let monitor = bluetooth
            let screen = dashScreen
            monitor.onLinkChange = { [weak screen] up in screen?.bikeLink(up) }
            screen.startAutoConnect()
            if monitor.status.isPositive { screen.bikeLink(true) }
            let cloud = model
            dashScreen.vehicleSource = {
                let car = cloud.vehicle
                // Both zero means the bike has not reported fuel, not an empty tank.
                let reported = (car?.fuelPercent ?? 0) > 0 || (car?.rangeKilometers ?? 0) > 0
                return DashScene.Vehicle(
                    connected: monitor.status.isPositive,
                    locked: monitor.isLocked,
                    voltage: monitor.batteryVoltage,
                    fuelPercent: reported ? car?.fuelPercent : nil,
                    rangeKm: reported ? car?.rangeKilometers.flatMap { $0 > 0 ? $0 : nil } : nil,
                    frontTireKPa: car?.frontTireKPa,
                    rearTireKPa: car?.rearTireKPa
                )
            }
            dashScreen.refreshVehicleData = { [weak cloud] in await cloud?.refreshQuietly() }
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
    @ObservedObject var parking: ParkingSpotTracker
    @State private var showsStylePicker = false
    @State private var showsFinder = false
    /// Seat or fuel lid that just opened; lit for a few seconds, as in the official app.
    @State private var justOpened: VehicleCommand?
    /// After the fuel lid opens or the fuel level jumps: offer to log the fill-up for a while.
    @State private var fuelPromptUntil: Date?
    @State private var showsFuelEntry = false
    @State private var lastFuelPercent: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(bluetooth: VehicleBluetoothMonitor, parking: ParkingSpotTracker) {
        self.bluetooth = bluetooth
        self.parking = parking
    }

    private var isLocked: Bool? {
        bluetooth.requiresRelock ? nil : (bluetooth.isLocked ?? model.vehicle?.isLocked)
    }
    private var batteryVoltage: Double? { bluetooth.batteryVoltage ?? model.vehicle?.batteryVoltage }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    if bluetooth.requiresRelock {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(bluetooth.signalInProgress ? "กำลังส่งสัญญาณและล็อกกลับ" : "ยังยืนยันการล็อกกลับไม่ได้",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            if !bluetooth.signalInProgress {
                                Button("ตรวจสอบและล็อกรถ") { showsFinder = true }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                    }
                    if model.vehicle == nil && model.isBusy {
                        dashboardSkeleton
                    } else if model.hasNoVehicle {
                        VStack(spacing: 16) {
                            Image(systemName: "motorcycle").font(.largeTitle).foregroundStyle(.secondary)
                            Text("ยังไม่มีรถที่พร้อมใช้งาน").font(.headline)
                            Text("ตรวจสอบการผูกรถใน ZONTES Smart แล้วกลับมาลองอีกครั้ง")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("ตรวจสอบอีกครั้ง") { Task { await model.refresh() } }
                                .buttonStyle(.borderedProminent)
                            Button("เปลี่ยนบัญชี") { model.logout() }
                        }
                        .padding(.vertical, 32)
                    } else {
                        connectionStrip
                        if dynamicTypeSize.isAccessibilitySize { accessibleStatus } else { statusBar }
                        vehicleImage
                        if dynamicTypeSize.isAccessibilitySize { controlGrid } else { controlWheel }
                        searchButton
                        lastUpdate
                        if model.vehicle == nil {
                            Text("โหลดข้อมูลรถไม่สำเร็จ แตะรีเฟรชเพื่อลองอีกครั้ง")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showsStylePicker) {
            VehicleStylePicker()
                .environmentObject(model)
        }
        .onAppear { configureBluetooth() }
        .onChange(of: model.vehicle?.carCode) { _ in configureBluetooth() }
        .onChange(of: model.vehicle?.mcuID) { _ in configureBluetooth() }
        .onChange(of: model.vehicle?.fuelPercent) { fuel in
            if let fuel, let before = lastFuelPercent, fuel - before >= 20 {
                fuelPromptUntil = Date().addingTimeInterval(20 * 60)
            }
            if let fuel { lastFuelPercent = fuel }
        }
        .overlay(alignment: .bottom) {
            if let until = fuelPromptUntil, until > Date() { fuelPrompt }
        }
        .sheet(isPresented: $showsFuelEntry, onDismiss: { fuelPromptUntil = nil }) {
            FuelEntryView(fill: nil)
        }
    }

    private var dashboardSkeleton: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                SkeletonBlock().frame(height: 48)
                SkeletonBlock().frame(height: 48)
            }
            SkeletonBlock().frame(height: 42)
            SkeletonBlock().frame(height: 190)
            Circle().fill(AppTheme.surface).frame(width: 252, height: 252)
            SkeletonBlock().frame(height: 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("กำลังโหลดข้อมูลรถ")
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
                if command == .fuelLid { fuelPromptUntil = Date().addingTimeInterval(20 * 60) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if justOpened == command { justOpened = nil }
            } catch {
                model.message = error.localizedDescription
            }
        }
    }

    private var fuelPrompt: some View {
        HStack(spacing: 14) {
            Button { showsFuelEntry = true } label: {
                Label("บันทึกการเติมน้ำมัน", systemImage: "fuelpump.fill")
                    .font(.subheadline.weight(.semibold))
            }
            Button { fuelPromptUntil = nil } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("ไม่บันทึก")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 10)
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
            .redacted(reason: model.vehicle == nil && model.isBusy ? .placeholder : [])
            Spacer(minLength: 0)
            RoundIconButton(systemImage: "arrow.clockwise", label: "รีเฟรช", isWorking: model.isBusy) {
                refreshAll()
            }
        }
    }

    private var connectionStrip: some View {
        HStack(spacing: 8) {
            ConnectionBadge(
                title: "ระบบรถ",
                value: model.vehicle.map { $0.isOnline ? "ออนไลน์" : "ออฟไลน์" } ?? "—",
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
        .frame(minHeight: 42)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var accessibleStatus: some View {
        VStack(spacing: 12) {
            LabeledContent("น้ำมัน", value: model.vehicle?.fuelPercent.map { "\($0)%" } ?? "—")
            LabeledContent("แบตเตอรี่", value: batteryVoltage.map { String(format: "%.1f V", $0) } ?? "—")
            LabeledContent("ระยะทางที่เหลือ", value: model.vehicle?.rangeKilometers.map { "\($0) km" } ?? "—")
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
    }

    private var controlGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach([VehicleCommand.lock, .unlock, .seat, .fuelLid]) { command in
                WheelButton(title: command.title, systemImage: command.systemImage,
                            isActive: (command == .lock && isLocked == true) || (command == .unlock && isLocked == false) || justOpened == command,
                            isWorking: bluetooth.commandInProgress == command, expanded: true) { run(command) }
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            }
        }
        .disabled(!bluetooth.status.isPositive || bluetooth.signalInProgress || bluetooth.commandInProgress != nil)
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
            if let url = model.vehicleImageURL {
                VehicleArtwork(url: url, maxPixelSize: 900)
            } else {
                vehiclePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .contentShape(Rectangle())
        .onTapGesture { showsStylePicker = true }
        .overlay(alignment: .bottomTrailing) {
            Button { showsStylePicker = true } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
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
                .fill(AppTheme.surface)
                .overlay { Circle().stroke(.white.opacity(0.08)) }

            wheelDivider.rotationEffect(.degrees(45))
            wheelDivider.rotationEffect(.degrees(-45))

            Group {
                WheelButton(title: "ฝาถัง", systemImage: "fuelpump.fill",
                            isActive: justOpened == .fuelLid,
                            isWorking: bluetooth.commandInProgress == .fuelLid) { run(.fuelLid) }
                    .offset(y: -82)

                WheelButton(title: "ล็อก", systemImage: "lock.fill",
                            isActive: isLocked == true,
                            isWorking: bluetooth.commandInProgress == .lock) { run(.lock) }
                    .offset(x: -82)

                WheelButton(title: "ปลดล็อก", systemImage: "lock.open.fill",
                            isActive: isLocked == false,
                            isWorking: bluetooth.commandInProgress == .unlock) { run(.unlock) }
                    .offset(x: 82)

                WheelButton(title: "เบาะ", systemImage: VehicleCommand.seat.systemImage,
                            isActive: justOpened == .seat,
                            isWorking: bluetooth.commandInProgress == .seat) { run(.seat) }
                    .offset(y: 82)
            }
            .disabled(!bluetooth.status.isPositive || bluetooth.signalInProgress || bluetooth.commandInProgress != nil)

            Image(systemName: bluetooth.status.isPositive ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(bluetooth.status.isPositive ? Color.cyan : Color.secondary)
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
            .frame(width: 44, height: 44)
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
                            ForEach(0..<5) { _ in
                                HStack(spacing: 14) {
                                    SkeletonBlock().frame(width: 76, height: 58)
                                    SkeletonBlock().frame(height: 18)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("กำลังโหลดรุ่นรถ")
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
                            Text("เลือกรุ่นและสีรถของคุณ")
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
            .background(AppTheme.background)
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
            // The catalog's "small" picture is usually the larger download (about 640 KB against
            // 260 KB), and this is the picture the dashboard shows once chosen.
            VehicleArtwork(url: style.imageURL, maxPixelSize: 240)
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
                Text(title)
                    .font(.caption2.weight(.medium))
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
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct WheelButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var isWorking = false
    var expanded = false
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
                    .font(expanded ? .body.weight(.medium) : .caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(expanded ? 12 : 0)
            .frame(width: expanded ? nil : 64)
            .frame(maxWidth: expanded ? .infinity : nil, minHeight: 52)
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
    @AppStorage(DashSettings.speedCamerasKey) private var speedCameras = true
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
                    Toggle("เตือนกล้องตรวจจับความเร็ว", isOn: $speedCameras)
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
            .background(AppTheme.background)
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
    @ObservedObject var trips: TripRecorder
    @ObservedObject private var fuel = FuelLog.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { TripsView(recorder: trips) } label: {
                        RideLinkRow(symbol: "point.topleft.down.curvedto.point.bottomright.up", tint: .blue, title: "ทริป",
                                    value: trips.current != nil ? "กำลังบันทึก" : (trips.trips.isEmpty ? "" : "\(trips.trips.count)"))
                    }
                    NavigationLink { FuelLogView() } label: {
                        RideLinkRow(symbol: "fuelpump.fill", tint: .orange, title: "เติมน้ำมัน",
                                    value: fuel.stats.overallKmPerLiter.map { String(format: "%.1f กม./ลิตร", $0) } ?? "")
                    }
                }

                Section("ข้อมูลรถ") {
                    MetricRow(title: "แบตเตอรี่", value: model.vehicle?.batteryVoltage.map { String(format: "%.1f V", $0) } ?? "--")
                    MetricRow(title: "ลมยางหน้า", value: model.vehicle?.frontTireKPa.map { "\($0) kPa" } ?? "--")
                    MetricRow(title: "ลมยางหลัง", value: model.vehicle?.rearTireKPa.map { "\($0) kPa" } ?? "--")
                    MetricRow(title: "ระยะถึงเช็กระยะ", value: model.vehicle?.maintenanceKilometers.map { "\($0) km" } ?? "--")
                    MetricRow(title: "ดาวเทียม", value: model.vehicle?.satelliteCount.map(String.init) ?? "--")
                }
                .redacted(reason: model.vehicle == nil && model.isBusy ? .placeholder : [])

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
            .background(AppTheme.background)
            .navigationTitle("ดูแลรถ")
        }
    }
}

private struct RideLinkRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
    @ObservedObject var bluetooth: VehicleBluetoothMonitor
    @ObservedObject var dashScreen: DashScreenService
    @ObservedObject var parking: ParkingSpotTracker

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
                            Text("ZONTES Smart")
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

                Section("การตั้งค่า") {
                    NavigationLink {
                        ConnectionDiagnosticsView(bluetooth: bluetooth, dashScreen: dashScreen)
                    } label: {
                        Label("ตรวจการเชื่อมต่อ", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        DataManagementView(dashScreen: dashScreen, parking: parking)
                    } label: {
                        Label("จัดการข้อมูล", systemImage: "externaldrive")
                    }
                }

                Section("เกี่ยวกับแอปและข้อมูล") {
                    ForEach(AppPolicy.allCases) { policy in
                        NavigationLink {
                            AppPolicyView(policy: policy)
                        } label: {
                            Label(policy.title, systemImage: policy.symbol)
                        }
                    }
                }

                Section {
                    Button("ออกจากระบบ", role: .destructive) { model.logout() }
                } footer: {
                    Text("ไม่บันทึกรหัสผ่าน · ลบเซสชันเมื่อออกจากระบบ")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("บัญชี")
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
