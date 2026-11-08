import CoreLocation
import Foundation
import MapKit

/// A place to navigate to, small enough to keep in the recent list.
struct DashDestination: Codable, Hashable, Identifiable {
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var id: String { String(format: "%.5f,%.5f", latitude, longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.subtitle = subtitle
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    init(_ item: MKMapItem) {
        let placemark = item.placemark
        let parts = [placemark.thoroughfare, placemark.subLocality, placemark.locality, placemark.administrativeArea]
        let subtitle = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        self.init(name: item.name ?? placemark.title ?? "ปลายทาง", subtitle: subtitle, coordinate: placemark.coordinate)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

/// Turn-by-turn guidance from Apple's routes: progress along the route, rerouting when we leave
/// it, arrival. Fed raw location fixes by DashScreenService.
@MainActor
final class DashNavigator: ObservableObject {
    enum Status: Equatable {
        case idle, guiding, rerouting, arrived
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var destination: DashDestination?
    @Published private(set) var route: DashRoute?
    @Published private(set) var progress: DashRouteProgress?
    @Published private(set) var recents: [DashDestination] = RecentDestinations.load()

    /// A new route (first or after rerouting), so maps along it can be prepared.
    var onRoute: (@MainActor (DashRoute) -> Void)?

    private var offRouteSince: Date?
    private var lastReroute = Date.distantPast
    private var arrivedAt: Date?

    private func log(_ text: String) {
        EventLog.record("NAV", text)
    }

    var isNavigating: Bool { status != .idle }

    /// Asks Apple for a route by road from `origin` (or the current location) to `destination`.
    static func route(to destination: DashDestination, from origin: CLLocation?) async throws -> MKRoute {
        let request = MKDirections.Request()
        if let origin {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }
        request.destination = destination.mapItem
        request.transportType = .automobile
        request.highwayPreference = DashSettings.avoidHighways ? .avoid : .any
        request.tollPreference = DashSettings.avoidTolls ? .avoid : .any
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw ZontesError.message("ไม่พบเส้นทางไปยังจุดหมายนี้") }
        return route
    }

    func start(_ destination: DashDestination, route: MKRoute) {
        self.destination = destination
        let built = DashRoute(route)
        self.route = built
        progress = nil
        offRouteSince = nil
        arrivedAt = nil
        status = .guiding
        RecentDestinations.add(destination)
        recents = RecentDestinations.load()
        log("Guidance to \"\(destination.name)\": \(Int(built.distance)) m, \(Int(built.expectedTravelTime / 60)) min, " +
            "\(built.steps.count) steps, avoid highways \(DashSettings.avoidHighways), tolls \(DashSettings.avoidTolls).")
        onRoute?(built)
    }

    func stop() {
        if status != .idle { log("Guidance ended.") }
        status = .idle
        destination = nil
        route = nil
        progress = nil
    }

    func update(with location: CLLocation) {
        guard let route, let destination, status != .idle else { return }
        let progress = route.progress(at: location.coordinate, hint: self.progress?.segment)
        self.progress = progress

        if status == .arrived {
            if let arrivedAt, Date().timeIntervalSince(arrivedAt) > 20 { stop() }
            return
        }
        if progress.remainingDistance < 30 || DashRoute.meters(location.coordinate, destination.coordinate) < 25 {
            status = .arrived
            arrivedAt = Date()
            log("Arrived at \"\(destination.name)\".")
            return
        }

        // Off the route by more than 50 m for 5 s, with a usable fix: ask for a new one.
        if progress.offRoute > 50, location.horizontalAccuracy < 40 {
            if offRouteSince == nil { offRouteSince = Date() }
            if let since = offRouteSince, Date().timeIntervalSince(since) >= 5, status != .rerouting,
               Date().timeIntervalSince(lastReroute) > 10 {
                reroute(from: location, to: destination)
            }
        } else {
            offRouteSince = nil
        }
    }

    private func reroute(from location: CLLocation, to destination: DashDestination) {
        status = .rerouting
        lastReroute = Date()
        log("Off the route by \(Int(progress?.offRoute ?? 0)) m; rerouting.")
        Task {
            do {
                let route = try await Self.route(to: destination, from: location)
                guard self.destination == destination, self.status != .idle else { return }
                let built = DashRoute(route)
                self.route = built
                self.progress = nil
                self.offRouteSince = nil
                self.status = .guiding
                self.log("New route: \(Int(built.distance)) m, \(Int(built.expectedTravelTime / 60)) min.")
                self.onRoute?(built)
            } catch {
                self.log("Rerouting failed: \(error.localizedDescription)")
                if self.status == .rerouting { self.status = .guiding }
            }
        }
    }

    /// What the dash shows for the current guidance, or nil when not navigating.
    func sceneNavigation() -> DashScene.Navigation? {
        guard let destination, status != .idle else { return nil }
        guard let route, let progress else {
            return DashScene.Navigation(maneuver: .straight, distanceToManeuver: nil, instruction: "กำลังเริ่มนำทาง",
                                        arrival: nil, remainingDistance: nil, remainingTime: nil, upcoming: [],
                                        status: status, destinationName: destination.name)
        }
        let step = progress.nextStep.map { route.steps[$0] }
        let instruction: String
        switch status {
        case .arrived: instruction = destination.name
        case .rerouting: instruction = "กำลังหาเส้นทางใหม่"
        default:
            if let text = step?.instruction, !text.isEmpty { instruction = text } else { instruction = "ตรงไป" }
        }
        return DashScene.Navigation(
            maneuver: status == .arrived ? .arrive : (step?.maneuver ?? .arrive),
            distanceToManeuver: status == .arrived ? nil : progress.distanceToNextStep,
            instruction: instruction,
            arrival: Date().addingTimeInterval(progress.remainingTime),
            remainingDistance: progress.remainingDistance,
            remainingTime: progress.remainingTime,
            upcoming: route.upcoming(from: progress.distanceAlong, length: 3000),
            status: status,
            destinationName: destination.name
        )
    }
}

/// The last few destinations, newest first.
enum RecentDestinations {
    private static let key = "dash.recentDestinations"
    private static let limit = 8

    static func load() -> [DashDestination] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([DashDestination].self, from: data)
        else { return [] }
        return list
    }

    static func add(_ destination: DashDestination) {
        var list = load().filter { $0.id != destination.id }
        list.insert(destination, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
