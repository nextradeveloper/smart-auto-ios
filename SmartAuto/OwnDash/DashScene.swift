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

    var date = Date()
    var location: CLLocation?
    var map: DashMapImage?
    var vehicle = Vehicle()
}

/// A rendered map picture and the Web Mercator rectangle it covers, so any coordinate can be
/// placed on it with plain arithmetic, on any thread.
struct DashMapImage {
    let image: CGImage
    let mapRect: MKMapRect

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

    func set(location: CLLocation) {
        lock.lock(); self.location = location; lock.unlock()
    }

    func set(map: DashMapImage) {
        lock.lock(); self.map = map; lock.unlock()
    }

    func set(vehicle: DashScene.Vehicle) {
        lock.lock(); self.vehicle = vehicle; lock.unlock()
    }

    func scene() -> DashScene {
        lock.lock(); defer { lock.unlock() }
        return DashScene(date: Date(), location: location, map: map, vehicle: vehicle)
    }
}
