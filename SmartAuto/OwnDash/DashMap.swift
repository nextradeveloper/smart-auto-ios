import CoreLocation
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

/// Apple Maps pictures for the dash: muted, no points of interest, light or dark.
///
/// One picture covers more than the screen shows, so the renderer slides (and turns) it under us
/// and a new one is only needed every couple of hundred metres.
///
/// Field log 2026-11-08: every map snapshot that worked was taken with the app in front; riding
/// with the phone locked, the map stopped loading. So while the app is in front, map tiles around
/// us and along the whole route are saved on the phone (DashTiles), and behind the lock screen the
/// picture is put together from them with Core Graphics alone. A live snapshot is still tried
/// there once, and used for as long as it keeps working.
@MainActor
final class DashMapProvider: ObservableObject {
    enum Mode: Equatable, Sendable {
        /// Around us, turned to our heading: the Dashboard screen.
        case overview
        /// Turned to our heading around the puck: the guidance screen.
        case guidance

        var pixels: CGSize {
            // Square, so turning never shows an edge: the overview pane (824x496) reaches 481 px from
            // its centre, guidance (1280x528 around the puck) about 830.
            self == .overview ? CGSize(width: 1280, height: 1280) : CGSize(width: 2048, height: 2048)
        }
        /// A new picture once we are this many pixels from the centre of the current one: before
        /// an edge can come into view (overview pane 824x496; guidance turns 1280x528 around us).
        var refreshPixels: Double { self == .overview ? 120 : 150 }
    }

    /// Metres per pixel at zoom 1, both screens; DashSettings.zoom multiplies it. One scale, so one
    /// set of saved tiles serves both.
    static let metersPerPixel = 1.25

    private struct Picture {
        let center: MKMapPoint
        let rect: MKMapRect
        let mode: Mode
        let style: DashStyle
        let zoom: Double
        let fromTiles: Bool
        let requested: Date
    }

    var onMap: ((DashMapImage?) -> Void)?
    /// Map tiles along the route still being saved, for the app's progress bar.
    @Published private(set) var preparing: (done: Int, total: Int)?
    @Published private(set) var isSavingTiles = false

    private var mode: Mode = .overview
    private var style: DashStyle = .dark
    private var zoom: Double = 1
    private var current: Picture?
    private var here: MKMapPoint?
    private var inFlight: MKMapSnapshotter?
    private var inFlightSince = Date.distantPast
    private var lastLiveRequest = Date.distantPast
    private var composing = false
    private var lastCompose = Date.distantPast
    /// Seconds before composing again: longer while no tile is saved here.
    private var composeEvery: TimeInterval = 1
    /// Whether live snapshots work with the app behind the lock screen; nil until one is tried.
    private var liveWorksInBackground: Bool?
    private var reported: Set<String> = []
    private let decodeQueue = DispatchQueue(label: "smartauto.dash.mapdecode", qos: .userInitiated)

    // Saving tiles ahead.
    private var pending: [DashTiles.Key] = []
    private var queued: Set<DashTiles.Key> = []
    private var running = 0
    private var aroundCenter: MKMapPoint?
    private var routeKeys: Set<DashTiles.Key> = []
    private var routeFinished: Set<DashTiles.Key> = []
    private var routeMade = 0
    private var routeStarted = Date()
    private var preparedRoute: DashRoute?

    private static let snapshotTimeout: TimeInterval = 12
    private static let parallelTiles = 3

    init() {
        DashTiles.tidyUp()
    }

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        current = nil
        pending = []
        queued = []
        isSavingTiles = running > 0
        aroundCenter = nil
        clearRoute()
        liveWorksInBackground = nil
    }

    func set(mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        // A picture of the new size on the next fix.
        current = nil
        lastLiveRequest = .distantPast
        lastCompose = .distantPast
        if mode == .overview { clearRoute() }
    }

    /// Light or dark pictures; switching saves new tiles, including those along the route.
    func set(style: DashStyle) {
        guard style != self.style else { return }
        self.style = style
        settingsChanged()
    }

    /// Closer or further maps; switching saves new tiles, including those along the route.
    func set(zoom: Double) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        settingsChanged()
    }

    private func settingsChanged() {
        current = nil
        lastLiveRequest = .distantPast
        lastCompose = .distantPast
        inFlight?.cancel()
        inFlight = nil
        pending = []
        queued = []
        aroundCenter = nil
        if let preparedRoute, mode == .guidance { prepare(along: preparedRoute) }
    }

    private var appInFront: Bool { UIApplication.shared.applicationState == .active }

    private func phoneState() -> String {
        if !UIApplication.shared.isProtectedDataAvailable { return "phone locked" }
        return appInFront ? "app in front" : "app in background"
    }

    /// Logs a line once per kind and phone state, so the log says what happened without repeating.
    private func note(_ kind: String, _ text: String) {
        let key = "\(kind)/\(phoneState())"
        guard !reported.contains(key) else { return }
        reported.insert(key)
        log(text)
    }

    private var tileLevel: (fine: Int, coarse: Int)? {
        guard let here else { return nil }
        let fine = DashTiles.level(metersPerPixel: Self.metersPerPixel * zoom, latitude: here.coordinate.latitude)
        return (fine, fine + DashTiles.coarseStep)
    }

    // MARK: Pictures

    func update(for location: CLLocation) {
        let point = MKMapPoint(location.coordinate)
        here = point
        if let inFlight, Date().timeIntervalSince(inFlightSince) > Self.snapshotTimeout {
            inFlight.cancel()
            self.inFlight = nil
            liveFailed("Map snapshot gave up after \(Int(Self.snapshotTimeout)) s (\(phoneState())).")
        }
        if appInFront { saveTilesAround(point) }
        pump()

        let stale = current.map(isStale) ?? true
        // Saved tiles first: instant, and the only map there is behind the lock screen.
        if stale, !composing, Date().timeIntervalSince(lastCompose) >= composeEvery {
            compose(around: point)
        }
        // A live snapshot is seamless (tiles can cut a label at their edge), so it replaces a tile
        // picture whenever MapKit will draw one.
        let wanted = stale || current?.fromTiles == true
        let liveAllowed = appInFront || liveWorksInBackground != false
        if wanted, liveAllowed, inFlight == nil, Date().timeIntervalSince(lastLiveRequest) >= 2 {
            snapshot(around: point)
        }
    }

    private func isStale(_ picture: Picture) -> Bool {
        guard picture.mode == mode, picture.style == style, picture.zoom == zoom else { return true }
        guard let here else { return false }
        let pixelsPerPoint = Double(mode.pixels.width) / picture.rect.width
        return hypot(here.x - picture.center.x, here.y - picture.center.y) * pixelsPerPoint >= mode.refreshPixels
    }

    /// Shows `picture` unless what is on screen now is better: a live picture beats a tile one
    /// while it still covers where we are, otherwise the newer request wins.
    private func show(_ picture: Picture, image: CGImage) {
        guard picture.mode == mode, picture.style == style, picture.zoom == zoom else { return }
        if let current, !isStale(current) {
            if picture.fromTiles && !current.fromTiles { return }
            if picture.fromTiles == current.fromTiles && picture.requested < current.requested { return }
        }
        current = picture
        onMap?(DashMapImage(image: image, mapRect: picture.rect))
    }

    nonisolated private static func rect(center: MKMapPoint, latitude: CLLocationDegrees, mode: Mode,
                                         zoom: Double) -> MKMapRect {
        let width = Double(mode.pixels.width) * metersPerPixel * zoom * MKMapPointsPerMeterAtLatitude(latitude)
        let height = width * Double(mode.pixels.height / mode.pixels.width)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    private func compose(around center: MKMapPoint) {
        guard let levels = tileLevel else { return }
        composing = true
        lastCompose = Date()
        let mode = mode, style = style, zoom = zoom, requested = Date()
        let rect = Self.rect(center: center, latitude: center.coordinate.latitude, mode: mode, zoom: zoom)
        decodeQueue.async { [weak self] in
            let result = DashTiles.compose(rect: rect, size: mode.pixels, dark: style == .dark,
                                           levels: [levels.coarse, levels.fine])
            Task { @MainActor in
                guard let self else { return }
                self.composing = false
                self.composeEvery = result == nil ? 5 : 1
                guard let result else {
                    self.note("tiles-none", "No saved map tiles here yet (\(self.phoneState())).")
                    return
                }
                self.show(Picture(center: center, rect: rect, mode: mode, style: style, zoom: zoom,
                                  fromTiles: true, requested: requested), image: result.image)
                self.note("tiles", "Map from saved tiles (\(self.phoneState())): \(result.fine) close-up, " +
                          "\(result.coarse) wide.")
            }
        }
    }

    private func liveFailed(_ text: String) {
        if !appInFront { liveWorksInBackground = false }
        note("failed", text)
    }

    private func snapshot(around center: MKMapPoint) {
        let mode = mode, style = style, zoom = zoom, requested = Date()
        let rect = Self.rect(center: center, latitude: center.coordinate.latitude, mode: mode, zoom: zoom)
        let snapshotter = MKMapSnapshotter(options: DashTiles.options(rect: rect, size: mode.pixels, dark: style == .dark))
        inFlight = snapshotter
        inFlightSince = requested
        lastLiveRequest = requested
        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snapshot, error in
            let image = snapshot?.image.cgImage
            Task { @MainActor in
                guard let self, self.inFlight === snapshotter else { return }
                self.inFlight = nil
                let seconds = String(format: "%.1f", Date().timeIntervalSince(requested))
                guard let image else {
                    self.liveFailed("Map snapshot failed (\(self.phoneState())): \(error?.localizedDescription ?? "no image").")
                    return
                }
                if !self.appInFront { self.liveWorksInBackground = true }
                self.show(Picture(center: center, rect: rect, mode: mode, style: style, zoom: zoom,
                                  fromTiles: false, requested: requested), image: image)
                self.note("ok", "Map snapshot ok in \(seconds) s (\(self.phoneState())).")
            }
        }
    }

    // MARK: Saving tiles ahead

    /// Close-up tiles 3 km around us and wide ones 15 km around, nearest first, each time we have
    /// moved 1.5 km. Tiles already saved are skipped, so a usual area costs nothing after the first ride.
    private func saveTilesAround(_ point: MKMapPoint) {
        guard let levels = tileLevel else { return }
        let perMeter = MKMapPointsPerMeterAtLatitude(point.coordinate.latitude)
        if let aroundCenter, hypot(point.x - aroundCenter.x, point.y - aroundCenter.y) / perMeter < 1500 { return }
        aroundCenter = point
        let dark = style == .dark
        enqueue(DashTiles.keys(around: point, radius: 3000 * perMeter, level: levels.fine, dark: dark)
                + DashTiles.keys(around: point, radius: 15_000 * perMeter, level: levels.coarse, dark: dark),
                first: false)
    }

    /// Saves tiles along the whole route (close-up within about 1.1 km of it, wide within 4 km) for
    /// when the phone is locked, ahead of anything else. Progress shows in the app.
    func prepare(along route: DashRoute) {
        preparedRoute = route
        let start = route.coordinate(at: 0)
        let latitude = start.latitude
        let fine = DashTiles.level(metersPerPixel: Self.metersPerPixel * zoom, latitude: latitude)
        let coarse = fine + DashTiles.coarseStep
        let perMeter = MKMapPointsPerMeterAtLatitude(latitude)
        let dark = style == .dark
        let length = min(route.distance, 200_000)

        var keys: [DashTiles.Key] = []
        var seen: Set<DashTiles.Key> = []
        func add(_ found: [DashTiles.Key]) {
            for key in found where seen.insert(key).inserted { keys.append(key) }
        }
        var along = 0.0
        while along <= length + 250 {
            let point = MKMapPoint(route.coordinate(at: min(along, length)))
            let half = 1100 * perMeter
            add(DashTiles.keys(covering: MKMapRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2),
                               level: fine, dark: dark))
            if Int(along) % 2000 < 250 {
                let wide = 4000 * perMeter
                add(DashTiles.keys(covering: MKMapRect(x: point.x - wide, y: point.y - wide, width: wide * 2, height: wide * 2),
                                   level: coarse, dark: dark))
            }
            along += 250
        }
        keys = Array(keys.prefix(1200))

        routeKeys = Set(keys)
        routeFinished = []
        routeMade = 0
        routeStarted = Date()
        preparing = (0, keys.count)
        // Tiles already queued count as soon as they finish; move them to the front with the rest.
        pending.removeAll { routeKeys.contains($0) }
        queued.subtract(routeKeys)
        enqueue(keys, first: true)
    }

    private func clearRoute() {
        preparedRoute = nil
        routeKeys = []
        preparing = nil
    }

    private func enqueue(_ keys: [DashTiles.Key], first: Bool) {
        let fresh = keys.filter { !queued.contains($0) }
        queued.formUnion(fresh)
        pending = first ? fresh + pending : pending + fresh
        pump()
    }

    /// Saves queued tiles a few at a time while the app is in front (MapKit does not draw behind the
    /// lock screen); picks up again on the next fix once it is back.
    private func pump() {
        while running < Self.parallelTiles, appInFront, !pending.isEmpty {
            let key = pending.removeFirst()
            running += 1
            Task { [weak self] in
                let result = await DashTiles.save(key)
                guard let self else { return }
                self.running -= 1
                self.queued.remove(key)
                self.finished(key, result)
                self.pump()
            }
        }
        let saving = running > 0 || !pending.isEmpty
        if isSavingTiles != saving { isSavingTiles = saving }
    }

    private func finished(_ key: DashTiles.Key, _ result: DashTiles.SaveResult) {
        if result == .failed { note("tile-failed", "Saving a map tile failed (\(phoneState())).") }
        guard routeKeys.contains(key), routeFinished.insert(key).inserted else { return }
        if result == .made { routeMade += 1 }
        let total = routeKeys.count
        let routeDone = routeFinished.count
        if routeDone >= total {
            log("Route map tiles ready: \(total) (\(routeMade) new) in " +
                String(format: "%.0f", Date().timeIntervalSince(routeStarted)) + " s.")
            preparing = nil
        } else if routeDone % 5 == 0 || routeDone == 1 {
            preparing = (routeDone, total)
        }
    }
}

/// Square map tiles saved on the phone, on a fixed Web Mercator grid so any tile is reused by every
/// later ride, light and dark kept apart. Close-up tiles are about 1.25 m a pixel; wide ones four
/// times that, drawn under the close-up ones where those are missing.
enum DashTiles {
    struct Key: Hashable, Sendable {
        let dark: Bool
        /// Tile width is 2^(level/4) map points: steps of about 19%, so a level fits any latitude.
        let level: Int
        let x: Int
        let y: Int
    }

    enum SaveResult: Sendable { case cached, made, failed }

    static let pixels = 1024
    /// Wide tiles are this many levels up: 2^(8/4) = 4 times the close-up tile.
    static let coarseStep = 8
    /// Tiles older than this are made again, for new roads.
    private static let maxAge: TimeInterval = 60 * 24 * 3600
    private static let diskLimit = 400 * 1024 * 1024

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashTiles", isDirectory: true)
    }

    static func level(metersPerPixel: Double, latitude: CLLocationDegrees) -> Int {
        let width = Double(pixels) * metersPerPixel * MKMapPointsPerMeterAtLatitude(latitude)
        return Int((log2(width) * 4).rounded())
    }

    static func width(_ level: Int) -> Double { pow(2, Double(level) / 4) }

    static func rect(_ key: Key) -> MKMapRect {
        let size = width(key.level)
        return MKMapRect(x: Double(key.x) * size, y: Double(key.y) * size, width: size, height: size)
    }

    static func keys(covering rect: MKMapRect, level: Int, dark: Bool) -> [Key] {
        let size = width(level)
        // A hair inside each edge, so a rect exactly on the grid does not reach the next tile.
        let x0 = Int(floor(rect.minX / size + 1e-9)), x1 = Int(floor(rect.maxX / size - 1e-9))
        let y0 = Int(floor(rect.minY / size + 1e-9)), y1 = Int(floor(rect.maxY / size - 1e-9))
        guard x1 >= x0, y1 >= y0 else { return [] }
        var keys: [Key] = []
        for y in y0...y1 {
            for x in x0...x1 { keys.append(Key(dark: dark, level: level, x: x, y: y)) }
        }
        return keys
    }

    /// Tiles within `radius` map points of `point`, nearest first.
    static func keys(around point: MKMapPoint, radius: Double, level: Int, dark: Bool) -> [Key] {
        let area = MKMapRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let size = width(level)
        func distance(_ key: Key) -> Double {
            hypot((Double(key.x) + 0.5) * size - point.x, (Double(key.y) + 0.5) * size - point.y)
        }
        return keys(covering: area, level: level, dark: dark)
            .filter { distance($0) <= radius + size / 2 }
            .sorted { distance($0) < distance($1) }
    }

    static func file(_ key: Key) -> URL {
        folder.appendingPathComponent(key.dark ? "dark" : "light", isDirectory: true)
            .appendingPathComponent(String(key.level), isDirectory: true)
            .appendingPathComponent("\(key.x)_\(key.y).jpg")
    }

    static func options(rect: MKMapRect, size: CGSize, dark: Bool) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(displayScale: 1),
        ])
        return options
    }

    private static func isFresh(_ url: URL) -> Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(date) < maxAge
    }

    /// Makes and saves `key` unless a recent copy is already on disk.
    static func save(_ key: Key) async -> SaveResult {
        let url = file(key)
        if isFresh(url) { return .cached }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = options(rect: rect(key), size: CGSize(width: pixels, height: pixels), dark: key.dark)
        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: settings).start(with: .global(qos: .utility)) { snapshot, _ in
                guard let image = snapshot?.image.cgImage, writeJPEG(image, to: url) else {
                    continuation.resume(returning: .failed)
                    return
                }
                continuation.resume(returning: .made)
            }
        }
    }

    /// The picture of `rect` at `size` from saved tiles, `levels` drawn in order (wide first, so
    /// close-up tiles cover them where saved). Nil when no tile is saved there. Core Graphics only,
    /// so it works behind the lock screen.
    static func compose(rect: MKMapRect, size: CGSize, dark: Bool, levels: [Int])
        -> (image: CGImage, fine: Int, coarse: Int)? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        let scale = Double(width) / rect.width
        var found: [Int] = []
        for level in levels {
            var count = 0
            for key in keys(covering: rect, level: level, dark: dark) {
                guard let image = readImage(file(key)) else { continue }
                let tile = DashTiles.rect(key)
                // Edges rounded the same way on both sides of a seam, so neighbours meet exactly.
                let left = ((tile.minX - rect.minX) * scale).rounded()
                let right = ((tile.maxX - rect.minX) * scale).rounded()
                let top = ((tile.minY - rect.minY) * scale).rounded()
                let bottom = ((tile.maxY - rect.minY) * scale).rounded()
                context.draw(image, in: CGRect(x: left, y: Double(height) - bottom, width: right - left, height: bottom - top))
                count += 1
            }
            found.append(count)
        }
        guard found.contains(where: { $0 > 0 }), let image = context.makeImage() else { return nil }
        return (image, found.last ?? 0, found.count > 1 ? found[0] : 0)
    }

    static func writeJPEG(_ image: CGImage, to file: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func readImage(_ file: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Removes the pictures of earlier versions and keeps saved tiles under the disk limit, oldest
    /// first. In the background, at start.
    static func tidyUp() {
        DispatchQueue.global(qos: .utility).async {
            let manager = FileManager.default
            let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? manager.removeItem(at: caches.appendingPathComponent("DashMaps", isDirectory: true))
            guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            var entries: [(url: URL, size: Int, date: Date)] = []
            var total = 0
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                entries.append((url, size, values.contentModificationDate ?? .distantPast))
                total += size
            }
            guard total > diskLimit else { return }
            for entry in entries.sorted(by: { $0.date < $1.date }) {
                try? manager.removeItem(at: entry.url)
                total -= entry.size
                if total < diskLimit * 3 / 4 { break }
            }
        }
    }
}
