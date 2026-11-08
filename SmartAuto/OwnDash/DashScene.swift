import CoreGraphics
import CoreLocation
import Foundation
import MapKit

/// Light or dark: the map pictures and every card follow it.
enum DashStyle: Equatable, Sendable {
    case dark, light
}

/// Everything one dash frame shows, copied out of the live state so drawing never waits on it.
struct DashScene {
    struct Vehicle: Equatable {
        var connected = false
        var locked: Bool?
        var voltage: Double?
    }

    struct Navigation {
        var maneuver: DashManeuver
        /// nil once arrived.
        var distanceToManeuver: Double?
        var instruction: String
        var arrival: Date?
        var remainingDistance: Double?
        var remainingTime: TimeInterval?
        /// The route ahead, from where we are, for the next few kilometres.
        var upcoming: [CLLocationCoordinate2D]
        var status: DashNavigator.Status
        var destinationName: String
        /// The turn right after the next one, when it comes within 150 m of it ("จากนั้น").
        var then: DashManeuver? = nil
    }

    var date = Date()
    /// The latest fix, for speed and accuracy.
    var location: CLLocation?
    /// Where to draw us this frame: the fix moved on by speed and smoothed (DashMotion).
    var position: CLLocationCoordinate2D?
    /// Smoothed heading, degrees clockwise from north; nil until we have moved.
    var course: Double?
    var map: DashMapImage?
    var vehicle = Vehicle()
    var navigation: Navigation?
    var style: DashStyle = .dark
    /// Guidance map scale when no picture has arrived yet (the picture carries its own).
    var guidanceMetersPerPixel = 1.25
    /// The phone's compass, many times a second; DashMotion turns it into the bike's heading.
    var compass: CompassSample?
    /// Guidance map tilted into perspective.
    var threeD = true
    /// Layout mirrored left to right.
    var mapOnRight = false
}

/// One compass reading: degrees clockwise from north, and when.
struct CompassSample: Equatable {
    let heading: Double
    let time: Date
}

/// A rendered map picture and the Web Mercator rectangle it covers, so any coordinate can be
/// placed on it with plain arithmetic, on any thread.
struct DashMapImage {
    let image: CGImage
    let mapRect: MKMapRect

    /// Picture pixels per Web Mercator map point.
    var pixelsPerMapPoint: Double { Double(image.width) / mapRect.width }

    /// The pixel in `image` (top-left origin) where `coordinate` falls.
    func pixel(for coordinate: CLLocationCoordinate2D) -> CGPoint {
        let point = MKMapPoint(coordinate)
        return CGPoint(
            x: (point.x - mapRect.minX) / mapRect.width * Double(image.width),
            y: (point.y - mapRect.minY) / mapRect.height * Double(image.height)
        )
    }
}

/// The live state the frame loop reads from, shared between the main thread and the render queue.
final class DashSceneStore {
    private let lock = NSLock()
    private var location: CLLocation?
    private var map: DashMapImage?
    private var vehicle = DashScene.Vehicle()
    private var navigation: DashScene.Navigation?
    private var style: DashStyle = .dark
    private var zoom = 1.0
    private var compass: CompassSample?
    private var threeD = true
    private var mapOnRight = false

    func set(location: CLLocation) {
        lock.lock(); self.location = location; lock.unlock()
    }

    func set(map: DashMapImage?) {
        lock.lock(); self.map = map; lock.unlock()
    }

    func set(vehicle: DashScene.Vehicle) {
        lock.lock(); self.vehicle = vehicle; lock.unlock()
    }

    func set(navigation: DashScene.Navigation?) {
        lock.lock(); self.navigation = navigation; lock.unlock()
    }

    func set(style: DashStyle) {
        lock.lock(); self.style = style; lock.unlock()
    }

    func set(zoom: Double) {
        lock.lock(); self.zoom = zoom; lock.unlock()
    }

    func set(mapOnRight: Bool) {
        lock.lock(); self.mapOnRight = mapOnRight; lock.unlock()
    }

    func set(threeD: Bool) {
        lock.lock(); self.threeD = threeD; lock.unlock()
    }

    func set(compass heading: Double) {
        lock.lock(); compass = CompassSample(heading: heading, time: Date()); lock.unlock()
    }

    func scene() -> DashScene {
        lock.lock(); defer { lock.unlock() }
        return DashScene(date: Date(), location: location, map: map, vehicle: vehicle, navigation: navigation,
                         style: style, guidanceMetersPerPixel: 1.25 * zoom, compass: compass, threeD: threeD,
                         mapOnRight: mapOnRight)
    }
}

/// Turns once-a-second GPS fixes into movement that looks continuous at the frame rate: the last
/// fix is carried forward along its course at its speed, and what is drawn eases towards that.
/// Without it the map jumped once a second, which read as stutter on the dash. Standing still, GPS
/// wanders a few metres a second; that is held, not followed (field log 2026-11-08: 20 fps on the
/// wire and still "กระตุก" with the bike parked).
///
/// Heading: GPS course only updates once a second and only when moving, so the map turned late. The
/// compass updates many times a second but says where the phone points, not the bike. While riding,
/// the angle between the two is learned; once it holds steady (phone in a mount), compass plus that
/// angle is the heading, live and also when slow or stopped. In a pocket it never holds steady, and
/// GPS course is used as before.
struct DashMotion {
    private var fix: CLLocation?
    private var shown: MKMapPoint?
    private var shownCourse: Double?
    private var lastCourse: Double?
    /// Bike heading minus compass, learned while moving, and how far it strays.
    private var mountOffset: Double?
    private var offsetError = 180.0

    /// Whether the compass, with the learned offset, is trusted for the heading.
    var compassTrusted: Bool { mountOffset != nil && offsetError < 15 }

    /// Call every frame with the latest fix; returns where to draw us and which way we face.
    mutating func step(latest: CLLocation?, compass: CompassSample? = nil,
                       now: Date = Date()) -> (CLLocationCoordinate2D?, Double?) {
        guard let latest else { return (nil, nil) }
        if fix?.timestamp != latest.timestamp {
            fix = latest
            if latest.course >= 0, latest.speed > 1.5 {
                lastCourse = latest.course
                learnOffset(course: latest.course, speed: latest.speed, compass: compass, now: now)
            }
        }

        // Carry the fix forward, at most 1.5 s, so a late fix does not send us flying.
        var target = MKMapPoint(latest.coordinate)
        if latest.speed > 1, let course = lastCourse {
            let age = min(1.5, max(0, now.timeIntervalSince(latest.timestamp)))
            let meters = latest.speed * age
            let perMeter = MKMapPointsPerMeterAtLatitude(latest.coordinate.latitude)
            let radians = course * .pi / 180
            target = MKMapPoint(x: target.x + sin(radians) * meters * perMeter,
                                y: target.y - cos(radians) * meters * perMeter)
        }

        if let current = shown {
            let perMeter = MKMapPointsPerMeterAtLatitude(latest.coordinate.latitude)
            let gap = hypot(target.x - current.x, target.y - current.y) / perMeter
            let parked = latest.speed < 0.8
            if gap > 60 {
                shown = target // first fix after a gap: jump
            } else if parked, gap < max(12, latest.horizontalAccuracy) {
                // Standing still: GPS drift, not movement.
            } else {
                // Moving: ease a sixth of the way each frame, about a third of a second at 20 fps.
                let rate = parked ? 0.05 : 1.0 / 6
                shown = MKMapPoint(x: current.x + (target.x - current.x) * rate,
                                   y: current.y + (target.y - current.y) * rate)
            }
        } else {
            shown = target
        }

        var heading = lastCourse
        if compassTrusted, let compass, let offset = mountOffset, now.timeIntervalSince(compass.time) < 1 {
            heading = Self.normalize(compass.heading + offset)
        }
        if let heading {
            if let current = shownCourse {
                shownCourse = Self.normalize(current + Self.difference(heading, current) * 0.25)
            } else {
                shownCourse = heading
            }
        }
        return (shown?.coordinate, shownCourse)
    }

    private mutating func learnOffset(course: Double, speed: Double, compass: CompassSample?, now: Date) {
        // Only well under way, with a fresh compass reading.
        guard speed > 4, let compass, now.timeIntervalSince(compass.time) < 1 else { return }
        let measured = Self.difference(course, compass.heading)
        guard let offset = mountOffset else {
            mountOffset = measured
            return
        }
        let error = abs(Self.difference(measured, offset))
        offsetError = offsetError * 0.8 + error * 0.2
        mountOffset = Self.normalize(offset + Self.difference(measured, offset) * 0.15)
    }

    /// a - b in degrees, in (-180, 180].
    static func difference(_ a: Double, _ b: Double) -> Double {
        var change = a - b
        while change > 180 { change -= 360 }
        while change <= -180 { change += 360 }
        return change
    }

    static func normalize(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
