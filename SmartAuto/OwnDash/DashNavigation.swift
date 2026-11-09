import CoreLocation
import Foundation
import MapKit

/// The arrow on the dash's turn card. Apple's route steps carry no turn type, only text, so it is
/// worked out from the route's geometry at each step (see DashRoute.maneuver).
enum DashManeuver: Equatable {
    case straight, slightLeft, slightRight, left, right, sharpLeft, sharpRight
    case uTurnLeft, uTurnRight, roundabout, arrive

    var symbol: String {
        switch self {
        case .straight: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .sharpLeft: return "arrow.turn.left.down"
        case .sharpRight: return "arrow.turn.right.down"
        case .uTurnLeft: return "arrow.uturn.left"
        case .uTurnRight: return "arrow.uturn.right"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .arrive: return "mappin.and.ellipse"
        }
    }

    static let allSymbols = [DashManeuver.straight, .slightLeft, .slightRight, .left, .right, .sharpLeft,
                             .sharpRight, .uTurnLeft, .uTurnRight, .roundabout, .arrive].map(\.symbol)

    /// `turn` is the change of heading in degrees, positive to the right.
    static func from(turn: Double, instruction: String, isLast: Bool) -> DashManeuver {
        if isLast { return .arrive }
        let text = instruction.lowercased()
        if text.contains("วงเวียน") || text.contains("roundabout") || text.contains("rotary") { return .roundabout }
        let size = abs(turn)
        let right = turn > 0
        switch size {
        case ..<20: return .straight
        case ..<45: return right ? .slightRight : .slightLeft
        case ..<135: return right ? .right : .left
        case ..<165: return right ? .sharpRight : .sharpLeft
        default: return right ? .uTurnRight : .uTurnLeft
        }
    }
}

/// A route reduced to what guidance needs: the line, how far along it each step begins, and the
/// arrow at each step.
struct DashRoute {
    struct Step: Equatable {
        let instruction: String
        let maneuver: DashManeuver
        /// Metres from the start of the route to where this step begins (its manoeuvre).
        let startDistance: Double
    }

    let coordinates: [CLLocationCoordinate2D]
    /// Metres from the start to each coordinate.
    let cumulative: [Double]
    let steps: [Step]
    let distance: Double
    let expectedTravelTime: TimeInterval
    /// Metres from the start to the end of each leg: each stop, then the destination.
    var legEnds: [Double] = []

    init(coordinates: [CLLocationCoordinate2D], steps: [(instruction: String, distance: Double)],
         expectedTravelTime: TimeInterval) {
        self.coordinates = coordinates
        var cumulative: [Double] = [0]
        for index in coordinates.indices.dropFirst() {
            cumulative.append(cumulative[index - 1] + Self.meters(coordinates[index - 1], coordinates[index]))
        }
        self.cumulative = cumulative
        distance = cumulative.last ?? 0
        self.expectedTravelTime = expectedTravelTime

        var built: [Step] = []
        var start = 0.0
        for (index, step) in steps.enumerated() {
            let maneuver: DashManeuver
            if index == 0 {
                maneuver = .straight
            } else {
                let turn = Self.turn(at: start, coordinates: coordinates, cumulative: cumulative)
                maneuver = DashManeuver.from(turn: turn, instruction: step.instruction, isLast: index == steps.count - 1)
            }
            built.append(Step(instruction: step.instruction, maneuver: maneuver, startDistance: min(start, distance)))
            start += step.distance
        }
        self.steps = built
        legEnds = [distance]
    }

    init(_ route: MKRoute) {
        self.init(legs: [route])
    }

    /// Legs joined end to end. Each leg after the first starts with an empty "start" step at the
    /// stop; that is folded into the step before, so the stop is one manoeuvre, not two. `lead` is
    /// where we are when the route was asked for from a point ahead of us: the stretch to it comes first.
    init(legs: [MKRoute], lead: CLLocationCoordinate2D? = nil) {
        var coordinates: [CLLocationCoordinate2D] = []
        var steps: [(instruction: String, distance: Double)] = []
        var ends: [Int] = []
        if let lead { coordinates.append(lead) }
        for (legIndex, leg) in legs.enumerated() {
            let count = leg.polyline.pointCount
            var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
            leg.polyline.getCoordinates(&points, range: NSRange(location: 0, length: count))
            if legIndex > 0, !points.isEmpty, !coordinates.isEmpty { points.removeFirst() }
            coordinates += points
            ends.append(max(0, coordinates.count - 1))
            for (stepIndex, step) in leg.steps.enumerated() {
                if step.instructions.isEmpty, legIndex > 0 || stepIndex > 0, !steps.isEmpty {
                    steps[steps.count - 1].distance += step.distance
                } else {
                    steps.append((step.instructions, step.distance))
                }
            }
        }
        if lead != nil, coordinates.count > 1, !steps.isEmpty {
            steps[0].distance += DashRoute.meters(coordinates[0], coordinates[1])
        }
        self.init(coordinates: coordinates, steps: steps,
                  expectedTravelTime: legs.reduce(0) { $0 + $1.expectedTravelTime })
        let cumulative = self.cumulative
        legEnds = ends.map { cumulative.isEmpty ? 0 : cumulative[min($0, cumulative.count - 1)] }
    }

    /// Where we are along the route. `hint` is the segment found last time, which keeps the search
    /// local on long routes and stops it jumping to a parallel stretch of the same road. `course`
    /// (when moving) prefers stretches that go our way, where the route comes back along a road.
    func progress(at coordinate: CLLocationCoordinate2D, hint: Int?, course: Double? = nil) -> DashRouteProgress {
        guard coordinates.count >= 2 else {
            return DashRouteProgress(segment: 0, distanceAlong: 0, offRoute: 0, nextStep: nil,
                                     distanceToNextStep: 0, remainingDistance: 0, remainingTime: 0)
        }
        func nearest(in range: Range<Int>) -> (segment: Int, along: Double, off: Double) {
            var best = (segment: range.lowerBound, along: 0.0, off: Double.greatestFiniteMagnitude)
            var bestScore = Double.greatestFiniteMagnitude
            for segment in range {
                let (fraction, off) = Self.project(coordinate, onto: coordinates[segment], coordinates[segment + 1])
                guard off < bestScore else { continue }
                var score = off
                if let course, cumulative[segment + 1] - cumulative[segment] > 1,
                   Self.angle(course, Self.bearing(coordinates[segment], coordinates[segment + 1])) > 100 {
                    score += 80
                }
                if score < bestScore {
                    bestScore = score
                    let along = cumulative[segment] + fraction * (cumulative[segment + 1] - cumulative[segment])
                    best = (segment, along, off)
                }
            }
            return best
        }
        let all = 0 ..< coordinates.count - 1
        var found: (segment: Int, along: Double, off: Double)
        if let hint {
            let window = max(0, hint - 20) ..< min(all.upperBound, hint + 200)
            found = nearest(in: window.isEmpty ? all : window)
            if found.off > 80 { found = nearest(in: all) }
        } else {
            found = nearest(in: all)
        }

        let next = steps.indices.dropFirst().first { steps[$0].startDistance > found.along + 3 }
        let toNext = next.map { steps[$0].startDistance - found.along } ?? max(0, distance - found.along)
        let remaining = max(0, distance - found.along)
        let time = distance > 0 ? expectedTravelTime * remaining / distance : 0
        return DashRouteProgress(segment: found.segment, distanceAlong: found.along, offRoute: found.off,
                                 nextStep: next, distanceToNextStep: toNext,
                                 remainingDistance: remaining, remainingTime: time)
    }

    /// The route from `along` onwards, for `length` metres, starting exactly at `along`.
    func upcoming(from along: Double, length: Double) -> [CLLocationCoordinate2D] {
        guard !coordinates.isEmpty else { return [] }
        var points = [coordinate(at: along)]
        for index in coordinates.indices where cumulative[index] > along {
            points.append(coordinates[index])
            if cumulative[index] > along + length { break }
        }
        return points
    }

    func coordinate(at along: Double) -> CLLocationCoordinate2D {
        Self.coordinate(at: along, coordinates: coordinates, cumulative: cumulative)
    }

    /// Direction of segment `segment`, degrees clockwise from north.
    func bearing(atSegment segment: Int) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        let index = max(0, min(segment, coordinates.count - 2))
        return Self.bearing(coordinates[index], coordinates[index + 1])
    }

    /// Whether `other` keeps to this route for its first `length` metres (nine in ten points every
    /// 250 m within 40 m of it): the same road, perhaps with a new time.
    func sharesRoad(with other: DashRoute, over length: Double) -> Bool {
        var along = 0.0, total = 0, on = 0
        while along <= min(length, other.distance) {
            total += 1
            if progress(at: other.coordinate(at: along), hint: nil).offRoute < 40 { on += 1 }
            along += 250
        }
        return total > 0 && Double(on) >= Double(total) * 0.9
    }

    // MARK: Geometry

    /// The angle between two bearings, 0 to 180 degrees.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let difference = abs((a - b).truncatingRemainder(dividingBy: 360))
        return difference > 180 ? 360 - difference : difference
    }

    /// Bearing from the first point to the one `meters` along the line, or nil if it is shorter.
    static func initialBearing(_ coordinates: [CLLocationCoordinate2D], over meters: Double) -> Double? {
        guard let first = coordinates.first else { return nil }
        var along = 0.0
        for index in coordinates.indices.dropFirst() {
            along += Self.meters(coordinates[index - 1], coordinates[index])
            if along >= meters { return bearing(first, coordinates[index]) }
        }
        guard let last = coordinates.last, along > 10 else { return nil }
        return bearing(first, last)
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Initial bearing from a to b, degrees clockwise from north.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The change of heading at `along`, measured 25 m either side, positive to the right.
    static func turn(at along: Double, coordinates: [CLLocationCoordinate2D], cumulative: [Double]) -> Double {
        let here = coordinate(at: along, coordinates: coordinates, cumulative: cumulative)
        let before = coordinate(at: max(0, along - 25), coordinates: coordinates, cumulative: cumulative)
        let after = coordinate(at: along + 25, coordinates: coordinates, cumulative: cumulative)
        guard meters(before, here) > 1, meters(here, after) > 1 else { return 0 }
        var change = bearing(here, after) - bearing(before, here)
        while change > 180 { change -= 360 }
        while change <= -180 { change += 360 }
        return change
    }

    static func coordinate(at along: Double, coordinates: [CLLocationCoordinate2D], cumulative: [Double]) -> CLLocationCoordinate2D {
        guard let first = coordinates.first else { return kCLLocationCoordinate2DInvalid }
        guard along > 0 else { return first }
        for index in coordinates.indices.dropFirst() where cumulative[index] >= along {
            let length = cumulative[index] - cumulative[index - 1]
            let fraction = length > 0 ? (along - cumulative[index - 1]) / length : 0
            let a = coordinates[index - 1], b = coordinates[index]
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                          longitude: a.longitude + (b.longitude - a.longitude) * fraction)
        }
        return coordinates[coordinates.count - 1]
    }

    /// Where `point` falls on segment a-b (0...1) and how far it is from it, in metres.
    static func project(_ point: CLLocationCoordinate2D, onto a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> (fraction: Double, meters: Double) {
        let scale = cos(a.latitude * .pi / 180) * 111_320
        let bx = (b.longitude - a.longitude) * scale, by = (b.latitude - a.latitude) * 110_540
        let px = (point.longitude - a.longitude) * scale, py = (point.latitude - a.latitude) * 110_540
        let length = bx * bx + by * by
        let fraction = length > 0 ? min(1, max(0, (px * bx + py * by) / length)) : 0
        let dx = px - bx * fraction, dy = py - by * fraction
        return (fraction, (dx * dx + dy * dy).squareRoot())
    }
}

struct DashRouteProgress: Equatable {
    var segment: Int
    var distanceAlong: Double
    /// Metres from the route line.
    var offRoute: Double
    /// Index into DashRoute.steps of the next manoeuvre, nil past the last one.
    var nextStep: Int?
    var distanceToNextStep: Double
    var remainingDistance: Double
    var remainingTime: TimeInterval
}

/// Distances and durations the way Apple Maps writes them in Thai.
enum DashFormat {
    static func distance(_ meters: Double) -> String {
        switch meters {
        case ..<100: return "\(max(10, Int((meters / 10).rounded()) * 10)) ม."
        case ..<1000: return "\(Int((meters / 50).rounded()) * 50) ม."
        case ..<10000: return String(format: "%.1f กม.", meters / 1000)
        default: return "\(Int((meters / 1000).rounded())) กม."
        }
    }

    /// ("18", "นาที") or ("1:05", "ชม.").
    static func duration(_ seconds: TimeInterval) -> (value: String, unit: String) {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return ("\(minutes)", "นาที") }
        return (String(format: "%d:%02d", minutes / 60, minutes % 60), "ชม.")
    }
}

extension MKPolyline {
    var allCoordinates: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
