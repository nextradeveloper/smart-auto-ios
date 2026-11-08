import MapKit
import SwiftUI

/// Rides recorded while the dash screen was on, newest first, with this month's total.
struct TripsView: View {
    @ObservedObject var recorder: TripRecorder
    @AppStorage(DashSettings.recordTripsKey) private var recordTrips = true

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

/// The ride on a map, its numbers, and GPX to share.
struct TripDetailView: View {
    let trip: TripSummary
    @ObservedObject var recorder: TripRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var points: [TripPoint] = []
    @State private var gpx: URL?

    var body: some View {
        List {
            Section {
                TripMapView(points: points)
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
        }
    }
}

/// The ride's line on an Apple map, start and end marked.
private struct TripMapView: UIViewRepresentable {
    let points: [TripPoint]

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.pointOfInterestFilter = .excludingAll
        view.isRotateEnabled = false
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        guard context.coordinator.shown != points.count, points.count >= 2 else { return }
        context.coordinator.shown = points.count
        view.removeOverlays(view.overlays)
        view.removeAnnotations(view.annotations)
        var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
        view.addOverlay(line)
        for (coordinate, title) in [(coordinates[0], "เริ่ม"), (coordinates[coordinates.count - 1], "จบ")] {
            let pin = MKPointAnnotation()
            pin.coordinate = coordinate
            pin.title = title
            view.addAnnotation(pin)
        }
        view.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30),
                               animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var shown = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
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
