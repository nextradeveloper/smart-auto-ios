import CoreLocation
import Foundation

/// A speed camera from OpenStreetMap (`highway=speed_camera`).
struct SpeedCamera: Codable, Equatable, Identifiable {
    let id: Int64
    let latitude: Double
    let longitude: Double
    /// km/h, when mapped.
    let limit: Double?
    /// Degrees clockwise from north that it faces traffic going, when mapped.
    let direction: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Speed cameras from OpenStreetMap through Overpass. Thailand's are mapped by volunteers, so many
/// are missing; Waze's and the paid databases are closed to other apps.
enum SpeedCameraSource {
    static func around(_ center: CLLocationCoordinate2D, radius: Double) async throws -> [SpeedCamera] {
        try await query("node(around:\(Int(radius)),\(String(format: "%.6f,%.6f", center.latitude, center.longitude)))[\"highway\"=\"speed_camera\"];out;")
    }

    /// Cameras within 60 m of a line (a route), a point every 200 m or so.
    static func along(_ line: [CLLocationCoordinate2D]) async throws -> [SpeedCamera] {
        var cameras: [SpeedCamera] = []
        var start = 0
        while start < line.count {
            let chunk = line[start ..< min(line.count, start + 300)]
            let text = chunk.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
            cameras += try await query("node(around:60,\(text))[\"highway\"=\"speed_camera\"];out;")
            start += 299
            if chunk.count < 300 { break }
        }
        return cameras
    }

    private static func query(_ body: String) async throws -> [SpeedCamera] {
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("SmartAuto/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = "[out:json][timeout:50];" + body
        request.httpBody = Data(("data=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ZontesError.message("เซิร์ฟเวอร์แผนที่ไม่ว่าง (\(http.statusCode))")
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [SpeedCamera] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { element in
            guard let id = (element["id"] as? NSNumber)?.int64Value,
                  let latitude = element["lat"] as? Double, let longitude = element["lon"] as? Double else { return nil }
            let tags = element["tags"] as? [String: String] ?? [:]
            return SpeedCamera(id: id, latitude: latitude, longitude: longitude,
                               limit: TripRoads.limit(tags), direction: direction(tags["direction"] ?? tags["camera:direction"]))
        }
    }

    /// "90", "NE", "N;S" (the first) to degrees; nil for "forward", "both" and the like.
    static func direction(_ value: String?) -> Double? {
        guard let value = value?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).uppercased() })
        else { return nil }
        if let degrees = Double(value) { return degrees }
        let points = ["N": 0.0, "NNE": 22.5, "NE": 45, "ENE": 67.5, "E": 90, "ESE": 112.5, "SE": 135, "SSE": 157.5,
                      "S": 180, "SSW": 202.5, "SW": 225, "WSW": 247.5, "W": 270, "WNW": 292.5, "NW": 315, "NNW": 337.5]
        return points[value]
    }
}

/// Which camera is ahead and how far, and when to say so. On a route: cameras within 40 m of it,
/// by distance along it. Without one: within 1 km straight ahead (inside 25° of our heading, and
/// facing our way when its direction is mapped). Cameras come for 15 km around us, again after
/// each 5 km, and along each new route.
@MainActor
final class SpeedCameraWatch {
    private var cameras: [Int64: SpeedCamera] = [:]
    private var areaCenter: CLLocation?
    private var fetchingArea = false
    private var lastFailure = Date.distantPast
    private var route: DashRoute?
    /// Metres along `route` of each camera on it.
    private var onRoute: [(camera: SpeedCamera, along: Double)] = []
    /// Announcements already made, per camera: 1 = about 1 km, 2 = about 300 m.
    private var said: [Int64: Int] = [:]
    private var reported = false

    private func log(_ text: String) {
        EventLog.record("CAMERA", text)
    }

    func reset() {
        route = nil
        onRoute = []
        said = [:]
    }

    /// Cameras along a new route; called for each route (start, rerouting).
    func prepare(along route: DashRoute) {
        self.route = route
        place()
        var line: [CLLocationCoordinate2D] = []
        var along = 0.0
        while along <= route.distance {
            line.append(route.coordinate(at: along))
            along += 200
        }
        Task {
            guard let found = try? await SpeedCameraSource.along(line) else { return }
            self.add(found)
        }
    }

    private func add(_ found: [SpeedCamera]) {
        let before = cameras.count
        for camera in found { cameras[camera.id] = camera }
        if cameras.count != before { log("\(cameras.count) speed cameras known nearby or on the route.") }
        place()
    }

    private func place() {
        guard let route else { onRoute = []; return }
        onRoute = cameras.values.compactMap { camera in
            let progress = route.progress(at: camera.coordinate, hint: nil)
            return progress.offRoute < 40 ? (camera, progress.distanceAlong) : nil
        }
        .sorted { $0.along < $1.along }
    }

    /// The camera ahead within 1.5 km, and what to say now (once per camera and distance).
    func update(_ location: CLLocation, progress: DashRouteProgress?, guiding: Bool)
        -> (ahead: DashScene.CameraAhead?, say: String?) {
        guard DashSettings.speedCameras else { return (nil, nil) }
        fetchAround(location)

        var best: (camera: SpeedCamera, distance: Double)?
        if guiding, route != nil, let progress {
            if let next = onRoute.first(where: { $0.along > progress.distanceAlong + 5 }),
               next.along - progress.distanceAlong <= 1500 {
                best = (next.camera, next.along - progress.distanceAlong)
            }
        } else if location.course >= 0, location.speed >= 3 {
            for camera in cameras.values {
                let target = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
                let distance = location.distance(from: target)
                guard distance > 15, distance <= 1000 else { continue }
                let bearing = DashRoute.bearing(location.coordinate, camera.coordinate)
                guard DashRoute.angle(bearing, location.course) <= 25 else { continue }
                if let facing = camera.direction, DashRoute.angle(facing, location.course) > 60 { continue }
                if distance < (best?.distance ?? .greatestFiniteMagnitude) { best = (camera, distance) }
            }
        }
        guard let best else { return (nil, nil) }

        let stage = best.distance <= 350 ? 2 : (best.distance <= 1050 ? 1 : 0)
        var speech: String?
        if stage > (said[best.camera.id] ?? 0) {
            said[best.camera.id] = stage
            let limit = best.camera.limit.map { " จำกัด \(Int($0))" } ?? ""
            speech = "อีก \(DashVoice.spokenDistance(best.distance)) กล้องตรวจจับความเร็ว\(limit)"
            if !reported { reported = true; log("First camera warning: \(Int(best.distance)) m ahead.") }
        }
        return (DashScene.CameraAhead(distance: best.distance, limit: best.camera.limit), speech)
    }

    private func fetchAround(_ location: CLLocation) {
        guard !fetchingArea, Date().timeIntervalSince(lastFailure) > 120 else { return }
        if let areaCenter, location.distance(from: areaCenter) < 5000 { return }
        fetchingArea = true
        Task {
            defer { self.fetchingArea = false }
            do {
                let found = try await SpeedCameraSource.around(location.coordinate, radius: 15_000)
                self.areaCenter = location
                self.add(found)
            } catch {
                self.lastFailure = Date()
            }
        }
    }
}
