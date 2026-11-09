import MapKit
import SwiftUI

/// Rides recorded while the dash screen was on, newest first, with this month's total.
struct TripsView: View {
    @ObservedObject var recorder: TripRecorder
    @AppStorage(DashSettings.recordTripsKey) private var recordTrips = true
    @AppStorage(DashSettings.assumedSpeedLimitKey) private var assumedLimit = 90.0

    var body: some View {
        List {
            Section {
                if let current = recorder.current {
                    HStack(spacing: 12) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text("กำลังบันทึก")
                        Spacer()
                        Text(RideFormat.kilometers(current.distance))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if !recorder.trips.isEmpty {
                    monthSummary
                }
                Toggle("บันทึกทริปเมื่อเปิดจอรถ", isOn: $recordTrips)
                Stepper(value: $assumedLimit, in: 40 ... 120, step: 10) {
                    HStack {
                        Text("ความเร็วจำกัดเมื่อไม่มีป้าย")
                        Spacer()
                        Text("\(Int(assumedLimit))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if recorder.trips.isEmpty {
                Section {
                    Text("เปิดจอรถแล้วออกขี่ ทริปจะถูกบันทึกเอง")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(recorder.trips) { trip in
                        NavigationLink { TripDetailView(trip: trip, recorder: recorder) } label: { TripRow(trip: trip) }
                    }
                    .onDelete { offsets in
                        for index in offsets { recorder.delete(recorder.trips[index].id) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("ทริป")
    }

    private var monthSummary: some View {
        let calendar = Calendar.current
        let month = recorder.trips.filter { calendar.isDate($0.start, equalTo: Date(), toGranularity: .month) }
        return HStack(spacing: 0) {
            RideStat(value: RideFormat.kilometers(month.reduce(0) { $0 + $1.distance }), label: "เดือนนี้")
            RideStat(value: "\(month.count)", label: "ทริป")
            RideStat(value: RideFormat.duration(month.reduce(0) { $0 + $1.movingTime }), label: "เวลาขี่")
        }
        .padding(.vertical, 4)
    }
}

private struct TripRow: View {
    let trip: TripSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.title)
                    .lineLimit(1)
                Text("\(RideFormat.day(trip.start)) · \(RideFormat.duration(trip.movingTime))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(RideFormat.kilometers(trip.distance))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}

/// A value over its label, centred; three across.
struct RideStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The ride on a map (stretches over the limit in red), its numbers, where it went too fast and on
/// which road, the roads it used, and GPX to share.
struct TripDetailView: View {
    let trip: TripSummary
    @ObservedObject var recorder: TripRecorder
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DashSettings.assumedSpeedLimitKey) private var assumedLimit = 90.0
    @State private var points: [TripPoint] = []
    @State private var gpx: URL?
    @State private var roads: [MappedRoad]?
    @State private var analysis: TripAnalysis?
    @State private var loadingRoads = false
    @State private var roadsError: String?
    @State private var focus: ClosedRange<Int>?

    var body: some View {
        List {
            Section {
                TripMapView(points: points, highlights: analysis?.speeding.map { $0.firstPoint ... $0.lastPoint } ?? [],
                            focus: focus)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                HStack(spacing: 0) {
                    RideStat(value: RideFormat.kilometers(trip.distance), label: "ระยะทาง")
                    RideStat(value: RideFormat.duration(trip.movingTime), label: "เวลาขี่")
                    RideStat(value: RideFormat.speed(trip.averageSpeed), label: "เฉลี่ย กม./ชม.")
                }
                .padding(.vertical, 6)
                HStack(spacing: 0) {
                    RideStat(value: RideFormat.speed(trip.maxSpeed), label: "สูงสุด กม./ชม.")
                    RideStat(value: RideFormat.lean(trip.maxLeanLeft), label: "เอียงซ้ายสุด")
                    RideStat(value: RideFormat.lean(trip.maxLeanRight), label: "เอียงขวาสุด")
                }
                .padding(.vertical, 6)
            } footer: {
                Text("\(RideFormat.day(trip.start)) – \(RideFormat.clock(trip.end)) · มุมเอียงเป็นค่าประมาณจากความเร็วและการเลี้ยว")
            }

            Section("เร็วเกินกำหนด") {
                if loadingRoads {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("กำลังดูถนนที่ผ่าน")
                            .foregroundStyle(.secondary)
                    }
                } else if let roadsError {
                    Text(roadsError)
                        .foregroundStyle(.secondary)
                    Button("ลองอีกครั้ง") { Task { await loadRoads() } }
                } else if let analysis {
                    if analysis.speeding.isEmpty {
                        Label("ไม่มีช่วงที่เร็วเกินกำหนด", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(analysis.speeding) { stretch in
                        Button { focus = stretch.firstPoint ... stretch.lastPoint } label: {
                            SpeedingRow(stretch: stretch, tripStart: trip.start)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let analysis, !analysis.roads.isEmpty {
                Section {
                    ForEach(analysis.roads) { road in RoadRow(road: road) }
                } header: {
                    Text("ถนนที่ผ่าน")
                } footer: {
                    Text("ความเร็วจำกัดจาก OpenStreetMap ถนนที่ไม่มีข้อมูลใช้ \(Int(assumedLimit)) กม./ชม. (วงเทา) " +
                         "ตั้งได้ในหน้าทริป · ความเร็วจาก GPS ต่ำกว่าหน้าปัดรถเล็กน้อย และนับเกินเมื่อเกิน \(Int(TripRoads.tolerance)) กม./ชม. ขึ้นไป")
                }
            }

            Section {
                if let gpx {
                    ShareLink(item: gpx) {
                        Label("ส่งออก GPX", systemImage: "square.and.arrow.up")
                    }
                }
                Button("ลบทริป", role: .destructive) {
                    recorder.delete(trip.id)
                    dismiss()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let id = trip.id
            let loaded = await Task.detached { TripStore.points(id) }.value
            points = loaded
            gpx = TripStore.gpx(trip, points: loaded)
            roads = TripStore.roads(id)
            if roads == nil { await loadRoads() } else { analyze() }
        }
        .onChange(of: assumedLimit) { _ in analyze() }
    }

    @MainActor
    private func loadRoads() async {
        guard points.count >= 2 else { return }
        loadingRoads = true
        roadsError = nil
        defer { loadingRoads = false }
        do {
            let found = try await TripRoads.fetch(points)
            TripStore.saveRoads(found, for: trip.id)
            roads = found
            analyze()
        } catch {
            roadsError = "ดูถนนที่ผ่านไม่ได้: \(error.localizedDescription)"
        }
    }

    private func analyze() {
        guard let roads else { return }
        analysis = TripRoads.analyze(points, roads: roads, assumedLimit: assumedLimit)
    }
}

private struct SpeedingRow: View {
    let stretch: SpeedingStretch
    let tripStart: Date

    var body: some View {
        HStack(spacing: 12) {
            SpeedLimitSign(limit: stretch.limit, signed: stretch.signed)
            VStack(alignment: .leading, spacing: 3) {
                Text(stretch.road)
                    .lineLimit(1)
                Text("\(RideFormat.clock(tripStart.addingTimeInterval(stretch.start))) · \(DashFormat.distance(max(stretch.distance, 10))) · \(RideFormat.duration(max(60, stretch.end - stretch.start)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(RideFormat.speed(stretch.maxSpeed))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.red)
                Text("กม./ชม.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct RoadRow: View {
    let road: RoadStretch

    var body: some View {
        HStack(spacing: 12) {
            SpeedLimitSign(limit: road.limit, signed: road.signed)
            VStack(alignment: .leading, spacing: 3) {
                Text(road.name)
                    .lineLimit(1)
                Text("\(DashFormat.distance(road.distance)) · เฉลี่ย \(RideFormat.speed(road.averageSpeed)) · สูงสุด \(RideFormat.speed(road.maxSpeed)) กม./ชม.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A round speed-limit sign: red ring from the map, grey where the rider's default stands in.
private struct SpeedLimitSign: View {
    let limit: Double
    let signed: Bool

    var body: some View {
        Text("\(Int(limit))")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(signed ? Color.primary : Color.secondary)
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(signed ? Color.red : Color.gray, lineWidth: 3))
    }
}

/// The ride's line on an Apple map, start and end marked, stretches over the limit in red; zooms
/// to `focus` when one is picked.
private struct TripMapView: UIViewRepresentable {
    let points: [TripPoint]
    var highlights: [ClosedRange<Int>] = []
    var focus: ClosedRange<Int>?

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.pointOfInterestFilter = .excludingAll
        view.isRotateEnabled = false
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        guard points.count >= 2 else { return }
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let key = "\(points.count)/\(highlights.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ","))"
        if coordinator.key != key {
            let first = coordinator.key.isEmpty
            coordinator.key = key
            view.removeOverlays(view.overlays)
            view.removeAnnotations(view.annotations)
            var all = coordinates
            let line = MKPolyline(coordinates: &all, count: all.count)
            view.addOverlay(line)
            for range in highlights where range.upperBound < coordinates.count {
                var part = Array(coordinates[range])
                if part.count == 1 { part.append(part[0]) }
                let over = MKPolyline(coordinates: &part, count: part.count)
                over.title = "over"
                view.addOverlay(over)
            }
            for (coordinate, title) in [(coordinates[0], "เริ่ม"), (coordinates[coordinates.count - 1], "จบ")] {
                let pin = MKPointAnnotation()
                pin.coordinate = coordinate
                pin.title = title
                view.addAnnotation(pin)
            }
            if first {
                view.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30),
                                       animated: false)
            }
        }
        if coordinator.focus != focus, let focus, focus.upperBound < coordinates.count {
            coordinator.focus = focus
            var part = Array(coordinates[max(0, focus.lowerBound - 3) ... min(coordinates.count - 1, focus.upperBound + 3)])
            let rect = MKPolyline(coordinates: &part, count: part.count).boundingMapRect
            let padded = rect.insetBy(dx: -max(400, rect.width * 0.3), dy: -max(400, rect.height * 0.3))
            view.setVisibleMapRect(padded, edgePadding: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var key = ""
        var focus: ClosedRange<Int>?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            let over = (overlay as? MKPolyline)?.title == "over"
            renderer.strokeColor = over ? .systemRed : .systemBlue
            renderer.lineWidth = over ? 6 : 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

/// Numbers for the ride and fuel pages, in Thai.
enum RideFormat {
    static func kilometers(_ meters: Double) -> String {
        String(format: meters < 100_000 ? "%.1f กม." : "%.0f กม.", meters / 1000)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        metersPerSecond > 0 ? String(Int((metersPerSecond * 3.6).rounded())) : "–"
    }

    static func lean(_ degrees: Double) -> String {
        degrees >= 3 ? "\(Int(degrees.rounded()))°" : "–"
    }

    /// "45 นาที" or "2 ชม. 05 นาที".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) นาที" }
        return String(format: "%d ชม. %02d นาที", minutes / 60, minutes % 60)
    }

    /// "8 พ.ย. 14:20".
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(formatter.string(from: date)) \(clock(date))"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func baht(_ value: Double) -> String {
        value >= 100 ? "฿\(Int(value.rounded()))" : String(format: "฿%.2f", value)
    }
}
