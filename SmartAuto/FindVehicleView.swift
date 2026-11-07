import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// How close the vehicle is, from its Bluetooth signal. Rough: a body, a wall or another
/// vehicle in between weakens it.
enum ProximityLevel: Int, Equatable {
    case far = 1, medium, near, veryClose

    init(rssi: Int) {
        if rssi >= -62 {
            self = .veryClose
        } else if rssi >= -74 {
            self = .near
        } else if rssi >= -86 {
            self = .medium
        } else {
            self = .far
        }
    }

    var bars: Int { rawValue }

    var title: String {
        switch self {
        case .far: return "ไกล"
        case .medium: return "ปานกลาง"
        case .near: return "ใกล้"
        case .veryClose: return "ใกล้มาก"
        }
    }

    var distanceText: String {
        switch self {
        case .far: return "มากกว่า 30 ม."
        case .medium: return "ประมาณ 20 ม."
        case .near: return "ประมาณ 10 ม."
        case .veryClose: return "น้อยกว่า 3 ม."
        }
    }

    /// Seconds between vibrations; quicker as the vehicle gets closer.
    var pulseInterval: TimeInterval? {
        switch self {
        case .far: return nil
        case .medium: return 1.2
        case .near: return 0.7
        case .veryClose: return 0.35
        }
    }

    var intensity: CGFloat {
        switch self {
        case .far: return 0.3
        case .medium: return 0.5
        case .near: return 0.75
        case .veryClose: return 1
        }
    }
}

private struct BikePin: Identifiable {
    let id = 0
    let coordinate: CLLocationCoordinate2D
}

/// Find the vehicle without a 4G module: the parked spot on a map, the Bluetooth signal for
/// the last stretch, and a chirp from the vehicle.
struct FindVehicleView: View {
    @ObservedObject var bluetooth: VehicleBluetoothMonitor
    @ObservedObject var parking: ParkingSpotTracker
    let vehicleName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var hasCentered = false
    @State private var vibrates = true
    @State private var isSignalling = false
    @State private var signalError: String?

    private var level: ProximityLevel? { bluetooth.signalStrength.map { ProximityLevel(rssi: $0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    map
                    spotCard
                    signalCard
                    actions
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("ค้นหารถ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ปิด") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { start() } else { stop() }
        }
        .onChange(of: parking.spot) { _ in centerOnSpot() }
        .onChange(of: parking.currentLocation) { _ in centerOnUserIfNoSpot() }
        .task { await pulse() }
    }

    // MARK: - Sections

    private var map: some View {
        Map(coordinateRegion: $region, showsUserLocation: true, annotationItems: pins) { pin in
            MapAnnotation(coordinate: pin.coordinate) {
                Image(systemName: "motorcycle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.cyan, in: Circle())
                    .overlay { Circle().stroke(.white, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            }
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var pins: [BikePin] {
        parking.spot.map { [BikePin(coordinate: $0.coordinate)] } ?? []
    }

    @ViewBuilder
    private var spotCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vehicleName.uppercased())
                .font(.headline)
            if let spot = parking.spot {
                Text("จอดไว้เมื่อ \(Self.timeText(spot.date)) · \(spot.source.title)")
                    .font(.subheadline)
                if let here = parking.currentLocation {
                    Text("ห่างจากคุณ \(Self.distanceText(here.distance(from: spot.location)))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                if spot.source == .walkAway {
                    Text("ตำแหน่งโดยประมาณ: บันทึกตอนสัญญาณหลุด รถอาจอยู่ห่างจากหมุด 20–50 ม. ใช้สัญญาณ Bluetooth ด้านล่างช่วยหาต่อ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("ยังไม่มีจุดจอด แอปจะจำให้เองเมื่อคุณกด Lock หรือเดินออกห่างจากรถจนสัญญาณ Bluetooth หลุด")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            permissionNote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var permissionNote: some View {
        switch parking.authorization {
        case .denied, .restricted:
            settingsNote("แอปยังไม่ได้รับสิทธิ์ตำแหน่ง จึงจำจุดจอดไม่ได้")
        case .authorizedWhenInUse:
            settingsNote("เลือกตำแหน่งเป็น \"ตลอดเวลา\" เพื่อให้จำจุดจอดได้แม้ไม่ได้เปิดแอป")
        default:
            EmptyView()
        }
    }

    private func settingsNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.orange)
            Button("เปิดการตั้งค่า") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.top, 4)
    }

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("สัญญาณ Bluetooth ของรถ", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("สั่นเตือน", isOn: $vibrates)
                    .labelsHidden()
                    .tint(.cyan)
            }
            if let level {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(1 ... 4, id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar <= level.bars ? Color.cyan : Color.white.opacity(0.12))
                            .frame(width: 14, height: CGFloat(10 + bar * 9))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.title)
                            .font(.title3.bold())
                        Text(level.distanceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                }
            } else {
                Text(bluetooth.status.isPositive
                     ? "กำลังวัดสัญญาณ…"
                     : "อยู่นอกระยะ Bluetooth ของรถ เดินไปตามแผนที่ สัญญาณจะขึ้นเองเมื่อเข้าใกล้ประมาณ 30–50 ม.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            actionButton(
                title: "ให้รถส่งเสียงและกระพริบไฟ",
                systemImage: "speaker.wave.2.fill",
                isWorking: isSignalling,
                isProminent: true
            ) { signal() }
            .disabled(!bluetooth.status.isPositive || isSignalling || bluetooth.commandInProgress != nil)

            Text(signalError ?? "ใช้ได้เมื่ออยู่ในระยะ Bluetooth · รถจะล็อกด้วย")
                .font(.caption)
                .foregroundStyle(signalError == nil ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let spot = parking.spot {
                actionButton(title: "นำทางไปที่รถ", systemImage: "figure.walk") { navigate(to: spot) }
            }

            actionButton(title: "บันทึกตำแหน่งนี้เป็นจุดจอด", systemImage: "mappin.and.ellipse") {
                parking.saveCurrentLocation()
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        isWorking: Bool = false,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().tint(isProminent ? .black : .white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isProminent ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behaviour

    private func start() {
        bluetooth.startProximity()
        parking.startLive()
        centerOnSpot()
    }

    private func stop() {
        bluetooth.stopProximity()
        parking.stopLive()
    }

    private func centerOnSpot() {
        guard let spot = parking.spot else { return }
        region = MKCoordinateRegion(center: spot.coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
        hasCentered = true
    }

    private func centerOnUserIfNoSpot() {
        guard parking.spot == nil, !hasCentered, let here = parking.currentLocation else { return }
        region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 600, longitudinalMeters: 600)
        hasCentered = true
    }

    private func signal() {
        isSignalling = true
        signalError = nil
        Task {
            do {
                try await bluetooth.signal()
            } catch {
                signalError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isSignalling = false
        }
    }

    /// Google Maps when installed, otherwise Apple Maps, on foot.
    private func navigate(to spot: ParkedSpot) {
        let coordinate = spot.coordinate
        if let url = URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=walking"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = vehicleName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// Vibrates quicker as the signal gets stronger.
    private func pulse() async {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        while !Task.isCancelled {
            guard vibrates, let level, let interval = level.pulseInterval else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            generator.impactOccurred(intensity: level.intensity)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private static func timeText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "วันนี้ \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "เมื่อวาน \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func distanceText(_ meters: CLLocationDistance) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) ม." }
        return String(format: "%.1f กม.", meters / 1000)
    }
}
