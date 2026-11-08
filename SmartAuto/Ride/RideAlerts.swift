import Foundation
import MapKit

/// What the dash warns about, most urgent first: fuel that will not reach the destination (or the
/// next stop), low fuel, soft tyres. From the bike's own data: fuel, range and TPMS.
enum RideAlerts {
    /// kPa. Below this a tyre reads soft; below `flatTire`, dangerously so.
    static let softTire = 190
    static let flatTire = 160
    /// Margin kept on top of the distance ahead before warning that fuel may not reach it.
    static let rangeMargin = 10_000.0

    static func alert(for vehicle: DashScene.Vehicle, distanceAhead: Double?) -> DashScene.Alert? {
        var alerts: [DashScene.Alert] = []
        if let range = vehicle.rangeKm, let ahead = distanceAhead, Double(range) * 1000 < ahead + rangeMargin {
            alerts.append(DashScene.Alert(text: "น้ำมันอาจไม่พอ", critical: true,
                                          spoken: "น้ำมันอาจไม่พอถึงจุดหมาย ควรแวะเติมน้ำมัน"))
        } else if let fuel = vehicle.fuelPercent, fuel <= 15 {
            alerts.append(DashScene.Alert(text: "น้ำมัน \(fuel)%", critical: fuel <= 8,
                                          spoken: "น้ำมันเหลือ \(fuel) เปอร์เซ็นต์"))
        }
        for (name, pressure) in [("หน้า", vehicle.frontTireKPa), ("หลัง", vehicle.rearTireKPa)] {
            guard let pressure, pressure > 0, pressure < softTire else { continue }
            alerts.append(DashScene.Alert(text: "ลมยาง\(name) \(pressure) kPa", critical: pressure < flatTire,
                                          spoken: "ลมยาง\(name)อ่อน"))
        }
        return alerts.first(where: \.critical) ?? alerts.first
    }
}

/// A fuel stop for a route longer than the tank: a station close to the route, before it runs dry.
enum FuelPlanner {
    /// Metres along the route to look for fuel: about 25 km before the range runs out, and no later
    /// than three quarters of it.
    static func target(routeDistance: Double, rangeMeters: Double) -> Double {
        let ideal = min(rangeMeters - 25_000, rangeMeters * 0.75)
        return max(0, min(max(1000, ideal), routeDistance - 1000))
    }

    /// The station nearest the route around `target` metres along it (then further back), or nil.
    static func station(along route: DashRoute, near target: Double) async -> DashDestination? {
        for along in [target, target * 0.6] {
            let request = MKLocalPointsOfInterestRequest(center: route.coordinate(at: along), radius: 6000)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            var best: (place: DashDestination, score: Double)?
            for item in items {
                let progress = route.progress(at: item.placemark.coordinate, hint: nil)
                guard progress.offRoute < 1500, progress.distanceAlong < route.distance - 500 else { continue }
                // Close to the road matters most; then close to where we want to stop.
                let score = progress.offRoute * 3 + abs(progress.distanceAlong - along) * 0.5
                if score < (best?.score ?? .greatestFiniteMagnitude) { best = (DashDestination(item), score) }
            }
            if let best { return best.place }
        }
        return nil
    }
}
