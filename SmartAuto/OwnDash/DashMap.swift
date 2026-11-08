import CoreLocation
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

/// Apple Maps pictures for the dash: dark, muted, no points of interest.
///
/// One picture covers more than the screen shows, so the renderer slides (and, navigating, turns)
/// it under us and a new one is only needed every few hundred metres. Whether MapKit renders with
/// the phone locked is not documented, so when guidance starts the pictures along the route are
/// made at once, while the app is in front, and kept on disk; the live snapshot is the fallback.
@MainActor
final class DashMapProvider: ObservableObject {
    enum Mode: Equatable, Sendable {
        /// North up, about a metre a pixel, around us: the Dashboard screen.
        case overview
        /// Turned to our heading by the renderer, so square and larger: the guidance screen.
        case guidance

        var pixels: CGSize {
            self == .overview ? CGSize(width: 1152, height: 768) : CGSize(width: 2048, height: 2048)
        }
        var metersPerPixel: Double { self == .overview ? 1.0 : 1.25 }
        /// A new picture once we are this many pixels from the centre of the current one: before
        /// an edge can come into view (overview pane 824x496; guidance turns 1280x528 around us).
        var refreshPixels: Double { self == .overview ? 120 : 150 }
    }

    var onMap: ((DashMapImage?) -> Void)?
    @Published private(set) var preparing: (done: Int, total: Int)?

    private var mode: Mode = .overview
    private var current: (center: MKMapPoint, rect: MKMapRect, mode: Mode)?
    private var inFlight: MKMapSnapshotter?
    private var lastRequest = Date.distantPast
    private var successes = 0
    private var failures = 0
    private var reportedLockedResult = false

    /// Guidance pictures made ahead, by centre.
    private var prepared: [(center: MKMapPoint, rect: MKMapRect, file: URL)] = []
    private var preparation: Task<Void, Never>?
    private let decodeQueue = DispatchQueue(label: "smartauto.dash.mapdecode", qos: .userInitiated)

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        current = nil
        preparation?.cancel()
        preparation = nil
        preparing = nil
    }

    func set(mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        // Force a picture at the new scale on the next fix.
        current = nil
        lastRequest = .distantPast
        if mode == .overview {
            preparation?.cancel()
            preparing = nil
        }
    }

    func update(for location: CLLocation) {
        guard inFlight == nil, Date().timeIntervalSince(lastRequest) >= 2 else { return }
        let here = MKMapPoint(location.coordinate)
        if let current, current.mode == mode {
            let pixelsPerPoint = Double(mode.pixels.width) / current.rect.width
            let distance = hypot(here.x - current.center.x, here.y - current.center.y) * pixelsPerPoint
            if distance < mode.refreshPixels { return }
        }
        lastRequest = Date()
        if mode == .guidance, let entry = nearestPrepared(to: here, latitude: location.coordinate.latitude) {
            load(entry, mode: mode)
            return
        }
        snapshot(center: here, latitude: location.coordinate.latitude, mode: mode)
    }

    // MARK: Live snapshots

    nonisolated private static func rect(center: MKMapPoint, latitude: CLLocationDegrees, mode: Mode) -> MKMapRect {
        let width = Double(mode.pixels.width) * mode.metersPerPixel * MKMapPointsPerMeterAtLatitude(latitude)
        let height = width * Double(mode.pixels.height / mode.pixels.width)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    nonisolated private static func options(rect: MKMapRect, mode: Mode) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = mode.pixels
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(displayScale: 1),
        ])
        return options
    }

    private func snapshot(center: MKMapPoint, latitude: CLLocationDegrees, mode: Mode) {
        let rect = Self.rect(center: center, latitude: latitude, mode: mode)
        let snapshotter = MKMapSnapshotter(options: Self.options(rect: rect, mode: mode))
        inFlight = snapshotter
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
                guard let image, self.mode == mode else {
                    if image == nil {
                        self.failures += 1
                        if self.failures == 1 || self.failures % 20 == 0 || (locked && !self.reportedLockedResult) {
                            self.log("Map snapshot failed (\(state), \(self.failures) so far): \(error?.localizedDescription ?? "no image").")
                            if locked { self.reportedLockedResult = true }
                        }
                    }
                    return
                }
                self.successes += 1
                self.current = (center, rect, mode)
                self.onMap?(DashMapImage(image: image, mapRect: rect))
                if self.successes == 1 || (locked && !self.reportedLockedResult) {
                    self.log("Map snapshot ok in \(seconds) s (\(state)).")
                    if locked { self.reportedLockedResult = true }
                }
            }
        }
    }

    // MARK: Pictures prepared along the route

    /// Makes guidance pictures every 300 m along the first 15 km of `route`, two at a time, and keeps
    /// them on disk for when the phone is locked. Replaces any earlier set.
    func prepare(along route: DashRoute) {
        preparation?.cancel()
        let spacing = 300.0
        let length = min(route.distance, 15_000)
        var centers: [CLLocationCoordinate2D] = []
        var along = 0.0
        while along <= length {
            centers.append(route.coordinate(at: along))
            along += spacing
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashMaps", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prepared = []
        preparing = (0, centers.count)
        let started = Date()

        preparation = Task { [weak self] in
            var made = 0
            var kept: [(center: MKMapPoint, rect: MKMapRect, file: URL)] = []
            await withTaskGroup(of: (MKMapPoint, MKMapRect, URL?).self) { group in
                var next = 0
                while next < min(2, centers.count) {
                    let index = next
                    group.addTask { await DashMapProvider.prepareOne(centers[index], index: index, folder: folder) }
                    next += 1
                }
                while let (center, rect, file) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let file { kept.append((center, rect, file)) }
                    made += 1
                    self?.prepared = kept
                    self?.preparing = (made, centers.count)
                    if next < centers.count {
                        let index = next
                        group.addTask { await DashMapProvider.prepareOne(centers[index], index: index, folder: folder) }
                        next += 1
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.log("Prepared \(kept.count) of \(centers.count) route maps in " +
                     String(format: "%.0f", Date().timeIntervalSince(started)) + " s.")
            self.preparing = nil
        }
    }

    nonisolated private static func prepareOne(_ coordinate: CLLocationCoordinate2D, index: Int,
                                               folder: URL) async -> (MKMapPoint, MKMapRect, URL?) {
        let center = MKMapPoint(coordinate)
        let mapRect = Self.rect(center: center, latitude: coordinate.latitude, mode: .guidance)
        let file = folder.appendingPathComponent("\(index).jpg")
        let ok = await render(rect: mapRect, to: file)
        return (center, mapRect, ok ? file : nil)
    }

    nonisolated private static func render(rect: MKMapRect, to file: URL) async -> Bool {
        let settings = Self.options(rect: rect, mode: .guidance)
        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: settings).start(with: .global(qos: .utility)) { snapshot, _ in
                guard let image = snapshot?.image.cgImage,
                      let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { continuation.resume(returning: false); return }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                continuation.resume(returning: CGImageDestinationFinalize(destination))
            }
        }
    }

    private func nearestPrepared(to point: MKMapPoint, latitude: CLLocationDegrees) -> (center: MKMapPoint, rect: MKMapRect, file: URL)? {
        let perMeter = MKMapPointsPerMeterAtLatitude(latitude)
        let best = prepared.min { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) }
        guard let best, hypot(best.center.x - point.x, best.center.y - point.y) / perMeter < 160 else { return nil }
        return best
    }

    private func load(_ entry: (center: MKMapPoint, rect: MKMapRect, file: URL), mode: Mode) {
        current = (entry.center, entry.rect, mode)
        let file = entry.file
        let rect = entry.rect
        decodeQueue.async { [weak self] in
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options)
            else { return }
            Task { @MainActor in
                guard let self, self.mode == mode else { return }
                self.onMap?(DashMapImage(image: image, mapRect: rect))
            }
        }
    }
}
