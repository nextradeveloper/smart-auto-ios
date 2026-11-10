import CoreLocation
import Foundation
import MapKit

/// One fill-up, as the pump and the dash show it.
struct FuelFill: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var liters: Double
    /// Baht paid.
    var total: Double
    /// The dash's odometer, km. Needed (on full fills) for km per litre.
    var odometer: Double?
    /// Filled to the top: the start or end of a km-per-litre measurement.
    var full = true
    var fuel: String
    var station = ""

    var pricePerLiter: Double { liters > 0 ? total / liters : 0 }

    static let fuels = ["95", "91", "E20", "เบนซิน"]
}

/// Km per litre, the way riders measure it: from one full tank to the next, odometer difference
/// over the litres put in since (the first full fill only sets the start).
struct FuelStats: Equatable {
    /// Per full fill that closes a measurement.
    var kmPerLiter: [UUID: Double] = [:]
    var overallKmPerLiter: Double?
    var bahtPerKm: Double?

    init(_ fills: [FuelFill]) {
        var startOdometer: Double?
        var liters = 0.0
        var baht = 0.0
        var totalDistance = 0.0, totalLiters = 0.0, totalBaht = 0.0
        for fill in fills.sorted(by: { $0.date < $1.date }) {
            liters += fill.liters
            baht += fill.total
            guard fill.full else { continue }
            if let start = startOdometer, let end = fill.odometer, end > start, liters > 0 {
                kmPerLiter[fill.id] = (end - start) / liters
                totalDistance += end - start
                totalLiters += liters
                totalBaht += baht
            }
            startOdometer = fill.odometer
            liters = 0
            baht = 0
        }
        if totalLiters > 0 { overallKmPerLiter = totalDistance / totalLiters }
        if totalDistance > 0 { bahtPerKm = totalBaht / totalDistance }
    }
}

/// Fill-ups on disk, newest first. Used from the main thread only (SwiftUI).
final class FuelLog: ObservableObject {
    static let shared = FuelLog()

    @Published private(set) var fills: [FuelFill] = []

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fuel-log.json")
    }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([FuelFill].self, from: data) {
            fills = saved.sorted { $0.date > $1.date }
        }
    }

    var stats: FuelStats { FuelStats(fills) }

    /// The latest odometer entered, to start the next one from.
    var lastOdometer: Double? { fills.first { $0.odometer != nil }?.odometer }
    var lastFuel: String { fills.first?.fuel ?? FuelFill.fuels[0] }

    /// Baht and litres this calendar month.
    func month(containing date: Date = Date()) -> (baht: Double, liters: Double) {
        let calendar = Calendar.current
        let inMonth = fills.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
        return (inMonth.reduce(0) { $0 + $1.total }, inMonth.reduce(0) { $0 + $1.liters })
    }

    func save(_ fill: FuelFill) {
        fills.removeAll { $0.id == fill.id }
        fills.append(fill)
        fills.sort { $0.date > $1.date }
        persist()
        EventLog.record("FUEL", String(format: "Fill saved: %.2f L, %.0f baht, full %@.", fill.liters, fill.total,
                                       fill.full ? "yes" : "no"))
    }

    func delete(_ ids: Set<UUID>) {
        fills.removeAll { ids.contains($0.id) }
        persist()
    }

    func deleteAll() throws {
        try AppDataFiles.removeIfPresent(file)
        fills = []
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fills) { try? data.write(to: file, options: .atomic) }
    }

    /// The fuel station we are at, if any: the nearest within 300 m of `location`.
    static func station(near location: CLLocation) async -> String? {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 300)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }
        return items.min {
            location.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))
                < location.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude))
        }?.name
    }
}
