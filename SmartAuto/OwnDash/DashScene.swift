import CoreGraphics
import CoreLocation
import Foundation
import MapKit

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

    func scene() -> DashScene {
        lock.lock(); defer { lock.unlock() }
        return DashScene(date: Date(), location: location, map: map, vehicle: vehicle, navigation: navigation)
    }
}

/// Turns once-a-second GPS fixes into movement that looks continuous at the frame rate: the last
/// fix is carried forward along its course at its speed, and what is drawn eases towards that.
/// Without it the map jumped once a second, which read as stutter on the dash.
struct DashMotion {
    private var fix: CLLocation?
    private var shown: MKMapPoint?
    private var shownCourse: Double?
    private var lastCourse: Double?

    /// Call every frame with the latest fix; returns where to draw us and which way we face.
    mutating func step(latest: CLLocation?, now: Date = Date()) -> (CLLocationCoordinate2D?, Double?) {
        guard let latest else { return (nil, nil) }
        if fix?.timestamp != latest.timestamp {
            fix = latest
            if latest.course >= 0, latest.speed > 1.5 { lastCourse = latest.course }
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
            // Far off (first fix after a gap): jump. Otherwise ease a third of the way each frame.
            shown = gap > 60 ? target : MKMapPoint(x: current.x + (target.x - current.x) * 0.3,
                                                   y: current.y + (target.y - current.y) * 0.3)
        } else {
            shown = target
        }

        if let course = lastCourse {
            if let current = shownCourse {
                var change = course - current
                while change > 180 { change -= 360 }
                while change <= -180 { change += 360 }
                shownCourse = (current + change * 0.2 + 360).truncatingRemainder(dividingBy: 360)
            } else {
                shownCourse = course
            }
        }
        return (shown?.coordinate, shownCourse)
    }
}
