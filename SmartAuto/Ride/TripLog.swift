import CoreLocation
import CoreMotion
import Foundation

/// One saved point of a ride. Short keys: a two-hour ride is about ten thousand of them.
struct TripPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    /// Seconds from the start of the trip.
    let time: Double
    /// Metres a second.
    let speed: Double

    private enum CodingKeys: String, CodingKey {
        case latitude = "a", longitude = "o", time = "t", speed = "v"
    }
}

/// A ride, without its points: what the list shows.
struct TripSummary: Codable, Identifiable, Equatable {
    let id: UUID
    var start: Date
    var end: Date
    /// Metres, counted only while moving, so GPS wander while parked adds nothing.
    var distance: Double
    var movingTime: TimeInterval
    /// Metres a second.
    var maxSpeed: Double
    /// Degrees; see LeanMeter.
    var maxLeanLeft: Double
    var maxLeanRight: Double
    var startName: String?
    var endName: String?

    var averageSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }

    var title: String {
        switch (startName, endName) {
        case let (start?, end?) where start != end: return "\(start) → \(end)"
        case let (start?, _): return start
        case let (nil, end?): return end
        default: return "ทริป"
        }
    }
}

/// Builds a trip from location fixes. A trip starts once we ride faster than about 11 km/h and
/// counts distance and time only while moving.
struct TripBuilder {
    static let startSpeed = 3.0
    static let movingSpeed = 1.0
    static let maxAccuracy = 30.0
    /// Shorter rides are not kept.
    static let minimumDistance = 500.0

    private(set) var summary: TripSummary?
    private(set) var points: [TripPoint] = []
    private var last: CLLocation?
    private var lastSaved: CLLocation?
    private var lastMoving: Date?

    /// Feeds one fix, with the largest lean each way since the last one (LeanMeter.takePeaks).
    mutating func add(_ fix: CLLocation, lean: (left: Double, right: Double) = (0, 0)) {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracy else { return }
        let speed = max(fix.speed, 0)
        if summary == nil {
            guard speed >= Self.startSpeed else { return }
            summary = TripSummary(id: UUID(), start: fix.timestamp, end: fix.timestamp, distance: 0, movingTime: 0,
                                  maxSpeed: 0, maxLeanLeft: 0, maxLeanRight: 0, startName: nil, endName: nil)
            points = []
            last = nil
            lastSaved = nil
            lastMoving = fix.timestamp
        }
        guard var trip = summary else { return }
        if let last {
            let seconds = fix.timestamp.timeIntervalSince(last.timestamp)
            guard seconds > 0 else { return }
            let meters = fix.distance(from: last)
            // A jump faster than 100 m/s is a bad fix, not a ride.
            if meters / seconds > 100 { return }
            if speed >= Self.movingSpeed {
                trip.distance += meters
                trip.movingTime += min(seconds, 10)
                trip.end = fix.timestamp
                lastMoving = fix.timestamp
            }
        }
        if fix.speedAccuracy < 0 || fix.speedAccuracy < 3 { trip.maxSpeed = max(trip.maxSpeed, speed) }
        trip.maxLeanLeft = max(trip.maxLeanLeft, lean.left)
        trip.maxLeanRight = max(trip.maxLeanRight, lean.right)

        let farEnough = lastSaved.map { fix.distance(from: $0) >= 15 } ?? true
        let longEnough = lastSaved.map { fix.timestamp.timeIntervalSince($0.timestamp) >= 30 && speed >= Self.movingSpeed } ?? true
        if farEnough || longEnough {
            points.append(TripPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                    time: fix.timestamp.timeIntervalSince(trip.start), speed: speed))
            lastSaved = fix
        }
        last = fix
        summary = trip
    }

    /// Seconds since we last moved, while a trip is under way.
    func idle(at date: Date) -> TimeInterval? {
        guard summary != nil, let lastMoving else { return nil }
        return date.timeIntervalSince(lastMoving)
    }

    /// Ends the trip; returns it when it is long enough to keep.
    mutating func finish() -> (summary: TripSummary, points: [TripPoint])? {
        defer {
            summary = nil
            points = []
            last = nil
            lastSaved = nil
            lastMoving = nil
        }
        guard let summary, summary.distance >= Self.minimumDistance else { return nil }
        return (summary, points)
    }

    /// Picks up a trip saved before the app was closed.
    mutating func resume(_ summary: TripSummary, points: [TripPoint]) {
        self.summary = summary
        self.points = points
    }
}

/// Lean angle without knowing how the phone is mounted: in a steady turn a bike leans by
/// atan(speed × turn rate / g). The turn rate is the gyro's rotation about the vertical, the same
/// for the bike and for a phone fixed to it or in the rider's pocket. An estimate; good to a few
/// degrees in steady corners.
final class LeanMeter {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var yawRate = 0.0 // guarded by lock; filtered, radians a second, positive turning left
    private var speed = 0.0 // guarded by lock
    private var peakLeft = 0.0 // guarded by lock
    private var peakRight = 0.0 // guarded by lock

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    static func lean(speed: Double, yawRate: Double) -> Double {
        atan(speed * yawRate / 9.81) * 180 / .pi
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity, rate = motion.rotationRate
            // Rotation about "up" (gravity points down), right-handed: positive is turning left.
            let up = -(rate.x * gravity.x + rate.y * gravity.y + rate.z * gravity.z)
            self.lock.lock()
            self.yawRate += (up - self.yawRate) * 0.15
            if self.speed >= 5 {
                let lean = Self.lean(speed: self.speed, yawRate: self.yawRate)
                // Beyond what a road bike reaches: a bump or the phone moving, not a corner.
                if abs(lean) <= 60 {
                    if lean > 0 { self.peakLeft = max(self.peakLeft, lean) } else { self.peakRight = max(self.peakRight, -lean) }
                }
            }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock()
        yawRate = 0
        peakLeft = 0
        peakRight = 0
        lock.unlock()
    }

    func set(speed: Double) {
        lock.lock(); self.speed = max(speed, 0); lock.unlock()
    }

    /// The largest lean each way since the last call.
    func takePeaks() -> (left: Double, right: Double) {
        lock.lock(); defer { lock.unlock() }
        let peaks = (peakLeft, peakRight)
        peakLeft = 0
        peakRight = 0
        return peaks
    }
}

/// Trips on disk: an index of summaries, and each trip's points in a file of its own.
enum TripStore {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Trips", isDirectory: true)
    }
    private static var indexFile: URL { folder.appendingPathComponent("index.json") }
    private static var currentFile: URL { folder.appendingPathComponent("current.json") }
    private static func pointsFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private struct Unfinished: Codable {
        let summary: TripSummary
        let points: [TripPoint]
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Newest first.
    static func summaries() -> [TripSummary] {
        (read([TripSummary].self, from: indexFile) ?? []).sorted { $0.start > $1.start }
    }

    static func points(_ id: UUID) -> [TripPoint] {
        read([TripPoint].self, from: pointsFile(id)) ?? []
    }

    static func save(_ summary: TripSummary, points: [TripPoint]) {
        write(points, to: pointsFile(summary.id))
        update(summary)
    }

    static func update(_ summary: TripSummary) {
        var all = summaries().filter { $0.id != summary.id }
        all.append(summary)
        write(all, to: indexFile)
    }

    static func delete(_ id: UUID) {
        write(summaries().filter { $0.id != id }, to: indexFile)
        try? FileManager.default.removeItem(at: pointsFile(id))
    }

    static func saveUnfinished(_ summary: TripSummary, points: [TripPoint]) {
        write(Unfinished(summary: summary, points: points), to: currentFile)
    }

    static func takeUnfinished() -> (summary: TripSummary, points: [TripPoint])? {
        defer { try? FileManager.default.removeItem(at: currentFile) }
        return read(Unfinished.self, from: currentFile).map { ($0.summary, $0.points) }
    }

    static func clearUnfinished() {
        try? FileManager.default.removeItem(at: currentFile)
    }

    /// The trip as GPX, for Strava, Google Earth or a friend's GPS. In the temporary folder.
    static func gpx(_ summary: TripSummary, points: [TripPoint]) -> URL? {
        let formatter = ISO8601DateFormatter()
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Smart Auto" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(escape(summary.title))</name><trkseg>

        """
        for point in points {
            let time = formatter.string(from: summary.start.addingTimeInterval(point.time))
            text += "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><time>\(time)</time></trkpt>\n"
        }
        text += "</trkseg></trk></gpx>\n"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SmartAuto-\(day.string(from: summary.start)).gpx")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Records rides while the dash screen is on (that is when location runs behind the lock screen).
/// A trip ends after 15 minutes without moving, or when the dash screen is turned off; a stop for
/// fuel or a coffee stays in the same trip.
@MainActor
final class TripRecorder: ObservableObject {
    /// The trip being recorded.
    @Published private(set) var current: TripSummary?
    /// Saved trips, newest first.
    @Published private(set) var trips: [TripSummary] = []

    private var builder = TripBuilder()
    private let lean = LeanMeter()
    private var active = false
    private var lastCheckpoint = Date.distantPast
    private static let idleLimit: TimeInterval = 15 * 60

    init() {
        if let unfinished = TripStore.takeUnfinished(), unfinished.summary.distance >= TripBuilder.minimumDistance {
            TripStore.save(unfinished.summary, points: unfinished.points)
            name(unfinished.summary, points: unfinished.points)
        }
        trips = TripStore.summaries()
    }

    private func log(_ text: String) {
        EventLog.record("TRIP", text)
    }

    func begin() {
        guard !active, DashSettings.recordTrips else { return }
        active = true
        lean.start()
    }

    func end() {
        guard active else { return }
        finish()
        lean.stop()
        active = false
    }

    func add(_ fix: CLLocation) {
        guard active else { return }
        lean.set(speed: fix.speed)
        let wasRecording = builder.summary != nil
        builder.add(fix, lean: lean.takePeaks())
        if !wasRecording, builder.summary != nil { log("Trip started.") }
        if let idle = builder.idle(at: fix.timestamp), idle > Self.idleLimit {
            finish()
            return
        }
        current = builder.summary
        if let summary = builder.summary, Date().timeIntervalSince(lastCheckpoint) > 60 {
            lastCheckpoint = Date()
            TripStore.saveUnfinished(summary, points: builder.points)
        }
    }

    func delete(_ id: UUID) {
        TripStore.delete(id)
        trips = TripStore.summaries()
    }

    private func finish() {
        let finished = builder.finish()
        TripStore.clearUnfinished()
        current = nil
        guard let finished else { return }
        TripStore.save(finished.summary, points: finished.points)
        trips = TripStore.summaries()
        log(String(format: "Trip saved: %.1f km, %.0f min moving.", finished.summary.distance / 1000,
                   finished.summary.movingTime / 60))
        name(finished.summary, points: finished.points)
    }

    /// Where it started and ended, in Thai, once the network answers.
    private func name(_ summary: TripSummary, points: [TripPoint]) {
        guard let first = points.first, let last = points.last else { return }
        Task {
            var named = summary
            named.startName = await Self.placeName(first)
            named.endName = await Self.placeName(last)
            guard named.startName != nil || named.endName != nil else { return }
            TripStore.update(named)
            self.trips = TripStore.summaries()
        }
    }

    private static func placeName(_ point: TripPoint) async -> String? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "th_TH")).first
        return placemark?.subLocality ?? placemark?.locality ?? placemark?.name
    }
}
