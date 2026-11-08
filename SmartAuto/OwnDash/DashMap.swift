import CoreLocation
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

/// Apple Maps pictures for the dash: muted, no points of interest, light or dark.
///
/// One picture covers more than the screen shows, so the renderer slides (and, navigating, turns)
/// it under us and a new one is only needed every few hundred metres. Whether MapKit renders with
/// the phone locked is not documented, so when guidance starts the pictures along the route are
/// made at once, while the app is in front, and kept on disk; the live snapshot is the fallback.
///
/// Field log 2026-11-08: the first snapshot took 107 s and blocked every other one. Now a snapshot
/// gives up after 12 s, and the last overview picture is kept on disk and shown at once next time.
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

    private struct Picture {
        let center: MKMapPoint
        let rect: MKMapRect
        let mode: Mode
        let style: DashStyle
    }

    var onMap: ((DashMapImage?) -> Void)?
    @Published private(set) var preparing: (done: Int, total: Int)?

    private var mode: Mode = .overview
    private var style: DashStyle = .dark
    private var current: Picture?
    private var inFlight: MKMapSnapshotter?
    private var inFlightSince = Date.distantPast
    private var lastRequest = Date.distantPast
    private var successes = 0
    private var failures = 0
    private var reported: Set<String> = []

    /// Guidance pictures made ahead, by centre.
    private var prepared: [(center: MKMapPoint, rect: MKMapRect, file: URL)] = []
    private var preparedRoute: DashRoute?
    private var preparation: Task<Void, Never>?
    private let decodeQueue = DispatchQueue(label: "smartauto.dash.mapdecode", qos: .userInitiated)

    private static let snapshotTimeout: TimeInterval = 12
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashMaps", isDirectory: true)
    }

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
        preparedRoute = nil
        prepared = []
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

    /// Light or dark pictures; switching makes new ones, including those along the route.
    func set(style: DashStyle) {
        guard style != self.style else { return }
        self.style = style
        current = nil
        lastRequest = .distantPast
        inFlight?.cancel()
        inFlight = nil
        if let preparedRoute, mode == .guidance { prepare(along: preparedRoute) }
    }

    /// Shows the last overview picture straight away if it covers `location`.
    func showSaved(for location: CLLocation) {
        guard mode == .overview, current == nil, let saved = SavedOverview.load(style: style) else { return }
        let here = MKMapPoint(location.coordinate)
        let margin = saved.rect.width * 0.2
        guard saved.rect.insetBy(dx: margin, dy: margin).contains(here) else { return }
        current = Picture(center: MKMapPoint(x: saved.rect.midX, y: saved.rect.midY), rect: saved.rect,
                          mode: .overview, style: style)
        onMap?(DashMapImage(image: saved.image, mapRect: saved.rect))
    }

    func update(for location: CLLocation) {
        if let inFlight, Date().timeIntervalSince(inFlightSince) > Self.snapshotTimeout {
            inFlight.cancel()
            self.inFlight = nil
            note("timeout", "Map snapshot gave up after \(Int(Self.snapshotTimeout)) s (\(phoneState())); trying again.")
        }
        guard inFlight == nil, Date().timeIntervalSince(lastRequest) >= 2 else { return }
        let here = MKMapPoint(location.coordinate)
        if let current, current.mode == mode, current.style == style {
            let pixelsPerPoint = Double(mode.pixels.width) / current.rect.width
            let distance = hypot(here.x - current.center.x, here.y - current.center.y) * pixelsPerPoint
            if distance < mode.refreshPixels { return }
        }
        lastRequest = Date()
        if mode == .guidance, let entry = nearestPrepared(to: here, latitude: location.coordinate.latitude) {
            load(entry)
            return
        }
        snapshot(center: here, latitude: location.coordinate.latitude)
    }

    // MARK: Live snapshots

    nonisolated private static func rect(center: MKMapPoint, latitude: CLLocationDegrees, mode: Mode) -> MKMapRect {
        let width = Double(mode.pixels.width) * mode.metersPerPixel * MKMapPointsPerMeterAtLatitude(latitude)
        let height = width * Double(mode.pixels.height / mode.pixels.width)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    nonisolated private static func options(rect: MKMapRect, mode: Mode, style: DashStyle) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = mode.pixels
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style == .dark ? .dark : .light),
            UITraitCollection(displayScale: 1),
        ])
        return options
    }

    private func phoneState() -> String {
        if !UIApplication.shared.isProtectedDataAvailable { return "phone locked" }
        return UIApplication.shared.applicationState == .active ? "app in front" : "app in background"
    }

    /// Logs a line once per kind and phone state, so the log says what happened without repeating.
    private func note(_ kind: String, _ text: String) {
        let key = "\(kind)/\(phoneState())"
        guard !reported.contains(key) else { return }
        reported.insert(key)
        log(text)
    }

    private func snapshot(center: MKMapPoint, latitude: CLLocationDegrees) {
        let mode = mode, style = style
        let rect = Self.rect(center: center, latitude: latitude, mode: mode)
        let snapshotter = MKMapSnapshotter(options: Self.options(rect: rect, mode: mode, style: style))
        inFlight = snapshotter
        inFlightSince = Date()
        let started = Date()
        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snapshot, error in
            let image = snapshot?.image.cgImage
            Task { @MainActor in
                guard let self, self.inFlight === snapshotter else { return }
                self.inFlight = nil
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                guard let image else {
                    self.failures += 1
                    self.note("failed", "Map snapshot failed (\(self.phoneState()), \(self.failures) so far): " +
                              "\(error?.localizedDescription ?? "no image").")
                    return
                }
                guard self.mode == mode, self.style == style else { return }
                self.successes += 1
                self.current = Picture(center: center, rect: rect, mode: mode, style: style)
                self.onMap?(DashMapImage(image: image, mapRect: rect))
                self.note("ok", "Map snapshot ok in \(seconds) s (\(self.phoneState())).")
                if mode == .overview { SavedOverview.save(image, rect: rect, style: style) }
            }
        }
    }

    // MARK: Pictures prepared along the route

    /// Makes guidance pictures every 300 m along the first 15 km of `route`, two at a time, and keeps
    /// them on disk for when the phone is locked. Replaces any earlier set.
    func prepare(along route: DashRoute) {
        preparation?.cancel()
        preparedRoute = route
        let spacing = 300.0
        let length = min(route.distance, 15_000)
        var centers: [CLLocationCoordinate2D] = []
        var along = 0.0
        while along <= length {
            centers.append(route.coordinate(at: along))
            along += spacing
        }
        let folder = Self.folder.appendingPathComponent("route", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prepared = []
        preparing = (0, centers.count)
        let started = Date()
        let style = style

        preparation = Task { [weak self] in
            var made = 0
            var kept: [(center: MKMapPoint, rect: MKMapRect, file: URL)] = []
            await withTaskGroup(of: (MKMapPoint, MKMapRect, URL?).self) { group in
                var next = 0
                while next < min(3, centers.count) {
                    let index = next
                    group.addTask { await DashMapProvider.prepareOne(centers[index], index: index, folder: folder, style: style) }
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
                        group.addTask { await DashMapProvider.prepareOne(centers[index], index: index, folder: folder, style: style) }
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

    nonisolated private static func prepareOne(_ coordinate: CLLocationCoordinate2D, index: Int, folder: URL,
                                               style: DashStyle) async -> (MKMapPoint, MKMapRect, URL?) {
        let center = MKMapPoint(coordinate)
        let mapRect = Self.rect(center: center, latitude: coordinate.latitude, mode: .guidance)
        let file = folder.appendingPathComponent("\(index).jpg")
        let settings = Self.options(rect: mapRect, mode: .guidance, style: style)
        let ok = await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: settings).start(with: .global(qos: .utility)) { snapshot, _ in
                guard let image = snapshot?.image.cgImage else { continuation.resume(returning: false); return }
                continuation.resume(returning: DashMapProvider.writeJPEG(image, to: file))
            }
        }
        return (center, mapRect, ok ? file : nil)
    }

    nonisolated static func writeJPEG(_ image: CGImage, to file: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated static func readImage(_ file: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private func nearestPrepared(to point: MKMapPoint, latitude: CLLocationDegrees) -> (center: MKMapPoint, rect: MKMapRect, file: URL)? {
        let perMeter = MKMapPointsPerMeterAtLatitude(latitude)
        let best = prepared.min { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) }
        guard let best, hypot(best.center.x - point.x, best.center.y - point.y) / perMeter < 160 else { return nil }
        return best
    }

    private func load(_ entry: (center: MKMapPoint, rect: MKMapRect, file: URL)) {
        let mode = mode, style = style
        current = Picture(center: entry.center, rect: entry.rect, mode: mode, style: style)
        let file = entry.file
        let rect = entry.rect
        decodeQueue.async { [weak self] in
            guard let image = DashMapProvider.readImage(file) else { return }
            Task { @MainActor in
                guard let self, self.mode == mode, self.style == style else { return }
                self.onMap?(DashMapImage(image: image, mapRect: rect))
            }
        }
    }
}

/// The last overview picture, per style, so the dash has a map the moment it starts.
private enum SavedOverview {
    private static func file(_ style: DashStyle) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashMaps", isDirectory: true)
            .appendingPathComponent("overview-\(style == .dark ? "dark" : "light").jpg")
    }

    private static func key(_ style: DashStyle) -> String { "dash.overviewRect.\(style == .dark ? "dark" : "light")" }

    static func save(_ image: CGImage, rect: MKMapRect, style: DashStyle) {
        let url = file(style)
        let defaultsKey = key(style)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async {
            guard DashMapProvider.writeJPEG(image, to: url) else { return }
            UserDefaults.standard.set([rect.origin.x, rect.origin.y, rect.size.width, rect.size.height], forKey: defaultsKey)
        }
    }

    static func load(style: DashStyle) -> (image: CGImage, rect: MKMapRect)? {
        guard let values = UserDefaults.standard.array(forKey: key(style)) as? [Double], values.count == 4,
              let image = DashMapProvider.readImage(file(style))
        else { return nil }
        return (image, MKMapRect(x: values[0], y: values[1], width: values[2], height: values[3]))
    }
}
