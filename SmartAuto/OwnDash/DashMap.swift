import CoreLocation
import MapKit
import UIKit

/// Apple Maps pictures for the dash: dark, muted, no points of interest, about one metre a pixel.
///
/// One picture covers more than the map pane shows, so the renderer slides it under the puck as we
/// move and a new one is only needed every few hundred metres. Whether MapKit renders with the phone
/// locked is not documented; the log says so the first time it is tried either way.
@MainActor
final class DashMapProvider {
    var onMap: ((DashMapImage) -> Void)?

    /// Pixels of the picture; the pane is about 824x496, so there is room to slide.
    private let pixelSize = CGSize(width: 1152, height: 768)
    private let metersAcross: Double = 1152
    /// A new picture once we are this far (in pixels) from the centre of the current one.
    private let refreshDistance: Double = 160
    private let minimumInterval: TimeInterval = 3

    private var currentCenter: MKMapPoint?
    private var currentRect: MKMapRect?
    private var inFlight: MKMapSnapshotter?
    private var lastRequest = Date.distantPast
    private var successes = 0
    private var failures = 0
    private var reportedLockedResult = false

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        currentCenter = nil
        currentRect = nil
    }

    func update(for location: CLLocation) {
        guard inFlight == nil, Date().timeIntervalSince(lastRequest) >= minimumInterval else { return }
        let here = MKMapPoint(location.coordinate)
        if let currentCenter, let currentRect {
            let pixelsPerPoint = Double(pixelSize.width) / currentRect.width
            let dx = (here.x - currentCenter.x) * pixelsPerPoint
            let dy = (here.y - currentCenter.y) * pixelsPerPoint
            if (dx * dx + dy * dy).squareRoot() < refreshDistance { return }
        }
        request(center: here, latitude: location.coordinate.latitude)
    }

    private func request(center: MKMapPoint, latitude: CLLocationDegrees) {
        let width = metersAcross * MKMapPointsPerMeterAtLatitude(latitude)
        let height = width * Double(pixelSize.height / pixelSize.width)
        let rect = MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = pixelSize
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(displayScale: 1),
        ])

        let snapshotter = MKMapSnapshotter(options: options)
        inFlight = snapshotter
        lastRequest = Date()
        let started = Date()
        let locked = !UIApplication.shared.isProtectedDataAvailable
        let background = UIApplication.shared.applicationState != .active
        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snapshot, error in
            let image = snapshot?.image.cgImage
            Task { @MainActor in
                guard let self, self.inFlight === snapshotter else { return }
                self.inFlight = nil
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let state = locked ? "phone locked" : (background ? "app in background" : "app in front")
                if let image {
                    self.successes += 1
                    self.currentCenter = center
                    self.currentRect = rect
                    self.onMap?(DashMapImage(image: image, mapRect: rect))
                    if self.successes == 1 || (locked && !self.reportedLockedResult) {
                        self.log("Map snapshot ok in \(seconds) s (\(state)).")
                        if locked { self.reportedLockedResult = true }
                    }
                } else {
                    self.failures += 1
                    if self.failures == 1 || self.failures % 20 == 0 || (locked && !self.reportedLockedResult) {
                        self.log("Map snapshot failed (\(state), \(self.failures) so far): " +
                                 "\(error?.localizedDescription ?? "no image").")
                        if locked { self.reportedLockedResult = true }
                    }
                }
            }
        }
    }
}
