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

/// One way to ride the trip: a route per leg (to each stop, then the destination).
struct DashTrip: Identifiable {
    let id = UUID()
    let legs: [MKRoute]

    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var expectedTravelTime: TimeInterval { legs.reduce(0) { $0 + $1.expectedTravelTime } }
    var hasTolls: Bool { legs.contains { $0.hasTolls } }
    var hasHighways: Bool { legs.contains { $0.hasHighways } }
    var turns: Int { legs.reduce(0) { $0 + $1.steps.count } }
    /// Apple's name for the way it goes ("ทล.1"); for one leg only.
    var name: String { legs.count == 1 ? legs[0].name : "" }

    /// What sets this one apart from the others, from Apple's own route data, as Apple Maps labels
    /// its choices: fastest, or how much slower, and no highways, no expressway, fewer turns, shorter.
    static func labels(for trip: DashTrip, among trips: [DashTrip]) -> [String] {
        guard let fastest = trips.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return [] }
        var labels: [String] = []
        if trip.id == fastest.id {
            labels.append("เร็วที่สุด")
        } else {
            let minutes = Int(((trip.expectedTravelTime - fastest.expectedTravelTime) / 60).rounded())
            if minutes > 0 { labels.append("+\(minutes) นาที") }
        }
        guard trips.count > 1 else { return labels }
        if !trip.hasHighways && trips.contains(where: \.hasHighways) { labels.append("เลี่ยงทางหลวง") }
        if !trip.hasTolls && trips.contains(where: \.hasTolls) { labels.append("ไม่มีทางด่วน") }
        let others = trips.filter { $0.id != trip.id }
        if let fewest = others.map(\.turns).min(), trip.turns < fewest { labels.append("ทางเลี้ยวน้อยกว่า") }
        if trip.id != fastest.id, let shortest = others.map(\.distance).min(), trip.distance < shortest - 500 {
            labels.append("ระยะทางสั้นกว่า")
        }
        return labels
    }
}

/// Turn-by-turn guidance from Apple's routes: progress along the route, stops on the way,
/// rerouting when we leave it, arrival. Fed raw location fixes by DashScreenService.
@MainActor
final class DashNavigator: ObservableObject {
    enum Status: Equatable {
        case idle, guiding, rerouting, arrived
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var destination: DashDestination?
    /// Stops still ahead, in order.
    @Published private(set) var stops: [DashDestination] = []
    @Published private(set) var route: DashRoute?
    @Published private(set) var progress: DashRouteProgress?
    @Published private(set) var recents: [DashDestination] = RecentDestinations.load()

    func clearRecents() {
        RecentDestinations.clear()
        recents = []
    }
    /// Stops reached since guidance started, for the voice.
    private(set) var stopsReached = 0

    /// A new route (first or after rerouting), so maps along it can be prepared.
    var onRoute: (@MainActor (DashRoute) -> Void)?
    /// Something to say about the route ("พบเส้นทางที่เร็วกว่า…").
    var onAnnounce: (@MainActor (String) -> Void)?
    private var lastFasterCheck = Date()
    private var checkingFaster = false

    private var offRouteSince: Date?
    private var lastReroute = Date.distantPast
    private var arrivedAt: Date?
    private var lastLocation: CLLocation?

    private func log(_ text: String) {
        EventLog.record("NAV", text)
    }

    var isNavigating: Bool { status != .idle }

    /// Metres to the next stop, or to the destination when no stop is left; nil when not guiding.
    var distanceAhead: Double? {
        guard let route, let progress, status == .guiding || status == .rerouting else { return nil }
        let legIndex = route.legEnds.count - 1 - stops.count
        if !stops.isEmpty, legIndex >= 0, legIndex < route.legEnds.count {
            return max(0, route.legEnds[legIndex] - progress.distanceAlong)
        }
        return progress.remainingDistance
    }

    private static func request(from origin: MKMapItem, to destination: MKMapItem) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = .automobile
        request.highwayPreference = DashSettings.avoidHighways ? .avoid : .any
        request.tollPreference = DashSettings.avoidTolls ? .avoid : .any
        return request
    }

    private static func origin(_ location: CLLocation?) -> MKMapItem {
        location.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? MKMapItem.forCurrentLocation()
    }

    /// Apple's ways by road from `origin` (or the current location) to `destination`, fastest first,
    /// up to three.
    static func routes(to destination: DashDestination, from origin: CLLocation?) async throws -> [MKRoute] {
        let request = Self.request(from: Self.origin(origin), to: destination.mapItem)
        request.requestsAlternateRoutes = true
        let routes = try await MKDirections(request: request).calculate().routes
            .sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        guard !routes.isEmpty else { throw ZontesError.message("ไม่พบเส้นทางไปยังจุดหมายนี้") }
        return Array(routes.prefix(3))
    }

    /// One route per leg: `origin` to the first place, then on to each next one. Apple routes one
    /// leg at a time, so stops are routed leg by leg, as Apple Maps does.
    static func legs(through places: [DashDestination], from origin: CLLocation?) async throws -> [MKRoute] {
        try await legs(through: places, start: Self.origin(origin))
    }

    private static func legs(through places: [DashDestination], start: MKMapItem) async throws -> [MKRoute] {
        var legs: [MKRoute] = []
        var from = start
        for place in places {
            let response = try await MKDirections(request: Self.request(from: from, to: place.mapItem)).calculate()
            guard let leg = response.routes.first else { throw ZontesError.message("ไม่พบเส้นทางไป \(place.name)") }
            legs.append(leg)
            from = place.mapItem
        }
        return legs
    }

    /// Where we will be `meters` on along `course`.
    nonisolated static func ahead(of coordinate: CLLocationCoordinate2D, course: Double, meters: Double) -> CLLocationCoordinate2D {
        let radians = course * .pi / 180
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + meters * cos(radians) / 111_320,
            longitude: coordinate.longitude + meters * sin(radians) / (111_320 * cos(coordinate.latitude * .pi / 180)))
    }

    /// Whether a route starts by turning back against `course`: its first 80 m head the other way,
    /// or one of its first steps, within 300 m, is a U-turn.
    nonisolated static func startsByTurningBack(_ coordinates: [CLLocationCoordinate2D], instructions: [(text: String, distance: Double)],
                                    course: Double) -> Bool {
        if let bearing = DashRoute.initialBearing(coordinates, over: 80), DashRoute.angle(bearing, course) > 100 {
            return true
        }
        var along = 0.0
        for step in instructions.prefix(3) where along < 300 {
            let text = step.text.lowercased()
            if text.contains("กลับรถ") || text.contains("u-turn") || text.contains("make a u") { return true }
            along += step.distance
        }
        return false
    }

    private static func alternates(from origin: MKMapItem, to place: DashDestination) async -> [MKRoute] {
        let request = Self.request(from: origin, to: place.mapItem)
        request.requestsAlternateRoutes = true
        return (try? await MKDirections(request: request).calculate().routes) ?? []
    }

    /// Routes on from where we are, the way we are going. Apple's directions take no heading, so
    /// asked from a point they often begin with "กลับรถ" back to the old road: riders found it kept
    /// forcing them back. So we also ask from a point ahead on our road, and take the quickest route
    /// that does not start by turning back (turning back costs it 5 minutes).
    static func legsAhead(through places: [DashDestination], from location: CLLocation?) async throws
        -> (legs: [MKRoute], lead: CLLocationCoordinate2D?) {
        guard let location, let first = places.first, location.course >= 0, location.speed >= 2 else {
            return (try await legs(through: places, from: location), nil)
        }
        let course = location.course, speed = location.speed
        let leadMeters = min(250, max(80, speed * 8))
        let aheadPoint = ahead(of: location.coordinate, course: course, meters: leadMeters)
        async let fromHere = alternates(from: Self.origin(location), to: first)
        async let fromAhead = alternates(from: MKMapItem(placemark: MKPlacemark(coordinate: aheadPoint)), to: first)
        let candidates = await fromHere.map { ($0, false) } + fromAhead.map { ($0, true) }
        var best: (route: MKRoute, ahead: Bool, cost: TimeInterval)?
        for (route, isAhead) in candidates {
            var cost = route.expectedTravelTime + (isAhead ? leadMeters / max(speed, 5) : 0)
            if startsByTurningBack(route.polyline.allCoordinates,
                                   instructions: route.steps.map { ($0.instructions, $0.distance) }, course: course) {
                cost += 300
            }
            if cost < (best?.cost ?? .greatestFiniteMagnitude) { best = (route, isAhead, cost) }
        }
        guard let best else { return (try await legs(through: places, from: location), nil) }
        let rest = try await legs(through: Array(places.dropFirst()), start: first.mapItem)
        return ([best.route] + rest, best.ahead ? location.coordinate : nil)
    }

    func start(_ destination: DashDestination, stops: [DashDestination], legs: [MKRoute]) {
        self.destination = destination
        self.stops = stops
        stopsReached = 0
        let built = DashRoute(legs: legs)
        self.route = built
        progress = nil
        offRouteSince = nil
        arrivedAt = nil
        lastFasterCheck = Date()
        status = .guiding
        RecentDestinations.add(destination)
        recents = RecentDestinations.load()
        log("Guidance to \"\(destination.name)\" with \(stops.count) stops: \(Int(built.distance)) m, " +
            "\(Int(built.expectedTravelTime / 60)) min, \(built.steps.count) steps, avoid highways " +
            "\(DashSettings.avoidHighways), tolls \(DashSettings.avoidTolls).")
        onRoute?(built)
    }

    func stop() {
        if status != .idle { log("Guidance ended.") }
        status = .idle
        destination = nil
        stops = []
        route = nil
        progress = nil
    }

    /// A stop before the others (a fuel station on the way, say); the route is made again through it.
    func addStop(_ place: DashDestination) {
        guard status != .idle else { return }
        stops.insert(place, at: 0)
        log("Stop added: \"\(place.name)\".")
        reroute("stop added")
    }

    /// Leaves out the next stop and goes on to the one after (or the destination).
    func skipStop() {
        guard status != .idle, !stops.isEmpty else { return }
        let skipped = stops.removeFirst()
        log("Stop skipped: \"\(skipped.name)\".")
        reroute("stop skipped")
    }

    func update(with location: CLLocation) {
        lastLocation = location
        guard let route, let destination, status != .idle else { return }
        let course = location.course >= 0 && location.speed >= 4 ? location.course : nil
        let progress = route.progress(at: location.coordinate, hint: self.progress?.segment, course: course)
        self.progress = progress

        if status == .arrived {
            if let arrivedAt, Date().timeIntervalSince(arrivedAt) > 20 { stop() }
            return
        }
        // Past the next stop (or close to it): on to the next leg.
        let legIndex = route.legEnds.count - 1 - stops.count
        if let next = stops.first, legIndex >= 0, legIndex < route.legEnds.count - 1,
           progress.distanceAlong >= route.legEnds[legIndex] - 30
            || DashRoute.meters(location.coordinate, next.coordinate) < 40 {
            stops.removeFirst()
            stopsReached += 1
            log("Reached stop \"\(next.name)\".")
        }
        if progress.remainingDistance < 30 || DashRoute.meters(location.coordinate, destination.coordinate) < 25 {
            status = .arrived
            arrivedAt = Date()
            log("Arrived at \"\(destination.name)\".")
            return
        }

        // Left the route: far from it, or near it but going another way (a frontage road, a turn
        // the route did not take, or turned round on the route itself). How long it must last
        // depends on how sure that is.
        let wrongWay = course.map { DashRoute.angle($0, route.bearing(atSegment: progress.segment)) > 90 } ?? false
        let usable = location.horizontalAccuracy < 40
        let needed: TimeInterval?
        if usable, progress.offRoute > 50 {
            needed = 4
        } else if usable, wrongWay, progress.offRoute > 25 {
            needed = 3
        } else if wrongWay {
            needed = 8
        } else if progress.offRoute > 30, location.horizontalAccuracy <= 10 {
            needed = 8
        } else {
            needed = nil
        }
        if let needed {
            if offRouteSince == nil { offRouteSince = Date() }
            if let since = offRouteSince, Date().timeIntervalSince(since) >= needed, status != .rerouting,
               Date().timeIntervalSince(lastReroute) > 8 {
                reroute(wrongWay ? "going another way, \(Int(progress.offRoute)) m off" : "off the route by \(Int(progress.offRoute)) m")
            }
        } else {
            offRouteSince = nil
        }

        // On the route: every 5 minutes, whether there is now a quicker way.
        if status == .guiding, needed == nil, !checkingFaster, location.speed >= 3,
           Date().timeIntervalSince(lastFasterCheck) > 300, Date().timeIntervalSince(lastReroute) > 120 {
            checkForFaster(from: location)
        }
    }

    /// Switches to a route found while riding: quicker by 3 minutes and a tenth at least, and not
    /// the same road with a new time. Said aloud, as the rider cannot tap anything.
    private func checkForFaster(from location: CLLocation) {
        guard let destination, let progress else { return }
        checkingFaster = true
        lastFasterCheck = Date()
        let places = stops + [destination]
        let remaining = progress.remainingTime
        Task {
            defer { self.checkingFaster = false }
            guard let found = try? await Self.legsAhead(through: places, from: location),
                  self.status == .guiding, self.destination == destination, self.stops + [destination] == places,
                  let current = self.route else { return }
            let saving = remaining - found.legs.reduce(0) { $0 + $1.expectedTravelTime }
            guard saving >= max(180, remaining * 0.1) else { return }
            let candidate = DashRoute(legs: found.legs, lead: found.lead)
            if current.sharesRoad(with: candidate, over: 5000) {
                self.log("Quicker estimate on the same road (\(Int(saving / 60)) min); route kept.")
                return
            }
            let minutes = Int((saving / 60).rounded())
            self.use(candidate)
            self.log("Faster route: \(minutes) min sooner, \(Int(candidate.distance)) m.")
            self.onAnnounce?("พบเส้นทางที่เร็วกว่า ประหยัด \(minutes) นาที")
        }
    }

    private func use(_ built: DashRoute) {
        route = built
        progress = nil
        offRouteSince = nil
        onRoute?(built)
    }

    /// A new route from here through the stops still ahead.
    private func reroute(_ reason: String) {
        guard let destination else { return }
        status = .rerouting
        lastReroute = Date()
        log("Rerouting: \(reason).")
        let places = stops + [destination]
        let location = lastLocation
        Task {
            do {
                let found = try await Self.legsAhead(through: places, from: location)
                guard self.destination == destination, self.status != .idle else { return }
                let built = DashRoute(legs: found.legs, lead: found.lead)
                self.status = .guiding
                self.use(built)
                self.log("New route: \(Int(built.distance)) m, \(Int(built.expectedTravelTime / 60)) min" +
                         (found.lead != nil ? ", from the road ahead." : "."))
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
        var then: DashManeuver?
        if status == .guiding, let next = progress.nextStep, next + 1 < route.steps.count,
           route.steps[next + 1].startDistance - route.steps[next].startDistance < 150 {
            then = route.steps[next + 1].maneuver
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
            destinationName: destination.name,
            then: then
        )
    }
}

/// The last few destinations, newest first.
enum RecentDestinations {
    private static let key = "dash.recentDestinations"
    private static let limit = 8

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

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
