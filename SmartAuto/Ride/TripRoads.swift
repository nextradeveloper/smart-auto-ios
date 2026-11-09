import CoreLocation
import Foundation

/// A road from OpenStreetMap near the ride: its name, its posted limit if mapped, its line.
struct MappedRoad: Codable, Equatable {
    let name: String
    /// km/h, when OpenStreetMap has the sign.
    let limit: Double?
    let latitudes: [Double]
    let longitudes: [Double]

    var count: Int { min(latitudes.count, longitudes.count) }
}

/// Part of a ride on one road.
struct RoadStretch: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    var distance: Double
    var movingTime: TimeInterval
    /// m/s
    var maxSpeed: Double
    /// km/h; `signed` says whether it is from the map or the rider's default.
    var limit: Double
    var signed: Bool

    var averageSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }
}

/// A stretch ridden above the limit.
struct SpeedingStretch: Codable, Equatable, Identifiable {
    var id: Int { firstPoint }
    let road: String
    /// km/h
    let limit: Double
    let signed: Bool
    /// m/s
    var maxSpeed: Double
    var distance: Double
    /// Seconds from the start of the trip.
    let start: Double
    var end: Double
    let firstPoint: Int
    var lastPoint: Int
}

struct TripAnalysis: Codable, Equatable {
    var roads: [RoadStretch]
    var speeding: [SpeedingStretch]
    /// km/h used where the map has no limit.
    var assumedLimit: Double
}

/// Which roads a ride used and where it went over the limit. Apple's maps do not give speed limits to
/// other apps, so roads and limits come from OpenStreetMap (Overpass), once per trip, kept with it.
enum TripRoads {
    /// km/h over the limit before it counts: GPS speed is true speed, a little under the speedometer.
    static let tolerance = 5.0
    /// A stretch must last this long to count.
    static let minimumSeconds = 5.0
    private static let matchMeters = 30.0

    // MARK: Fetch

    /// Roads within 30 m of the ride, from the public Overpass server.
    static func fetch(_ points: [TripPoint]) async throws -> [MappedRoad] {
        // A point every 60 m or so is enough to find the roads; in chunks the server accepts.
        var thinned: [TripPoint] = []
        for point in points {
            if let last = thinned.last, distance(last, point) < 60 { continue }
            thinned.append(point)
        }
        if let last = points.last, thinned.last != last { thinned.append(last) }
        var roads: [MappedRoad] = []
        var seen: Set<String> = []
        var start = 0
        while start < thinned.count {
            let chunk = Array(thinned[start ..< min(thinned.count, start + 400)])
            start += 399 // overlap by one so the line is unbroken
            for road in try await query(chunk) {
                let key = "\(road.name)|\(road.latitudes.first ?? 0)|\(road.longitudes.first ?? 0)|\(road.count)"
                if seen.insert(key).inserted { roads.append(road) }
            }
            if chunk.count < 400 { break }
        }
        return roads
    }

    private static func query(_ points: [TripPoint]) async throws -> [MappedRoad] {
        guard points.count >= 1 else { return [] }
        let line = points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let skip = "footway|path|cycleway|steps|pedestrian|track|bridleway|corridor|proposed|construction|platform"
        let text = "[out:json][timeout:90];way(around:\(Int(matchMeters)),\(line))[\"highway\"][\"highway\"!~\"\(skip)\"];out tags geom;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("SmartAuto/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(("data=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ZontesError.message("เซิร์ฟเวอร์แผนที่ไม่ว่าง (\(http.statusCode)) ลองใหม่อีกครั้ง")
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [MappedRoad] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { element in
            guard let tags = element["tags"] as? [String: String],
                  let geometry = element["geometry"] as? [[String: Double]], geometry.count >= 2 else { return nil }
            return MappedRoad(name: name(tags), limit: limit(tags),
                              latitudes: geometry.compactMap { $0["lat"] }, longitudes: geometry.compactMap { $0["lon"] })
        }
    }

    /// "ถนนพหลโยธิน (ทล.1)", the number alone, or what kind of road it is.
    static func name(_ tags: [String: String]) -> String {
        let name = tags["name:th"] ?? tags["name"]
        let ref = tags["ref"].map { $0.split(separator: ";").first.map(String.init) ?? $0 }
        switch (name, ref) {
        case let (name?, ref?) where !name.contains(ref): return "\(name) (ทล.\(ref))"
        case let (name?, _): return name
        case let (nil, ref?): return "ทางหลวง \(ref)"
        default:
            switch tags["highway"] ?? "" {
            case "motorway", "trunk", "primary": return "ทางหลวงไม่มีชื่อ"
            case "residential", "living_street": return "ถนนในหมู่บ้าน"
            case "service": return "ทางเข้าออก"
            default: return "ถนนไม่มีชื่อ"
            }
        }
    }

    /// km/h from maxspeed (motorcycle-specific first): "80", "50 mph", "TH:urban" (80), "TH:rural" (90).
    static func limit(_ tags: [String: String]) -> Double? {
        guard let value = (tags["maxspeed:motorcycle"] ?? tags["maxspeed"])?.trimmingCharacters(in: .whitespaces)
        else { return nil }
        switch value.lowercased() {
        case "th:urban": return 80
        case "th:rural": return 90
        default: break
        }
        let digits = value.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number > 0 else { return nil }
        return value.lowercased().contains("mph") ? (number * 1.609).rounded() : number
    }

    // MARK: Analyse

    /// Each point put on its road, then per road and the stretches over the limit.
    static func analyze(_ points: [TripPoint], roads: [MappedRoad], assumedLimit: Double) -> TripAnalysis {
        let onRoad = smooth(match(points, roads: roads))
        var stretches: [RoadStretch] = []
        var speeding: [SpeedingStretch] = []
        for index in points.indices {
            let point = points[index]
            let road = onRoad[index].map { roads[$0] }
            let name = road?.name ?? "นอกถนนในแผนที่"
            let signed = road?.limit != nil
            let limit = road?.limit ?? assumedLimit
            let slot: Int
            if let found = stretches.firstIndex(where: { $0.name == name }) {
                slot = found
            } else {
                stretches.append(RoadStretch(name: name, distance: 0, movingTime: 0, maxSpeed: 0, limit: limit, signed: signed))
                slot = stretches.count - 1
            }
            stretches[slot].maxSpeed = max(stretches[slot].maxSpeed, point.speed)
            // A mapped limit wins over the default where the road has both.
            if signed && !stretches[slot].signed { stretches[slot].limit = limit; stretches[slot].signed = true }
            var meters = 0.0
            if index > 0 {
                let previous = points[index - 1]
                meters = distance(previous, point)
                if point.speed >= 1 {
                    stretches[slot].distance += meters
                    stretches[slot].movingTime += min(point.time - previous.time, 30)
                }
            }

            guard point.speed * 3.6 > limit + tolerance, onRoad[index] != nil else { continue }
            if var last = speeding.last, last.road == name, point.time - last.end <= 10 {
                last.lastPoint = index
                last.end = point.time
                last.distance += meters
                last.maxSpeed = max(last.maxSpeed, point.speed)
                speeding[speeding.count - 1] = last
            } else {
                speeding.append(SpeedingStretch(road: name, limit: limit, signed: signed, maxSpeed: point.speed,
                                                distance: 0, start: point.time, end: point.time,
                                                firstPoint: index, lastPoint: index))
            }
        }
        speeding.removeAll { $0.end - $0.start < minimumSeconds }
        stretches.removeAll { $0.distance < 50 }
        return TripAnalysis(roads: stretches, speeding: speeding, assumedLimit: assumedLimit)
    }

    /// The road each point is on: the nearest road segment within 30 m, using a grid of about 110 m
    /// cells so long rides stay quick.
    static func match(_ points: [TripPoint], roads: [MappedRoad]) -> [Int?] {
        struct Cell: Hashable { let x: Int, y: Int }
        let size = 0.001
        func cell(_ latitude: Double, _ longitude: Double) -> Cell {
            Cell(x: Int(floor(longitude / size)), y: Int(floor(latitude / size)))
        }
        var grid: [Cell: [(road: Int, segment: Int)]] = [:]
        for (roadIndex, road) in roads.enumerated() where road.count >= 2 {
            for segment in 0 ..< road.count - 1 {
                let a = cell(road.latitudes[segment], road.longitudes[segment])
                let b = cell(road.latitudes[segment + 1], road.longitudes[segment + 1])
                for x in min(a.x, b.x) ... max(a.x, b.x) {
                    for y in min(a.y, b.y) ... max(a.y, b.y) {
                        grid[Cell(x: x, y: y), default: []].append((roadIndex, segment))
                    }
                }
            }
        }
        return points.map { point in
            let here = cell(point.latitude, point.longitude)
            let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            var best: (road: Int, off: Double)?
            for dx in -1 ... 1 {
                for dy in -1 ... 1 {
                    for (roadIndex, segment) in grid[Cell(x: here.x + dx, y: here.y + dy)] ?? [] {
                        let road = roads[roadIndex]
                        let a = CLLocationCoordinate2D(latitude: road.latitudes[segment], longitude: road.longitudes[segment])
                        let b = CLLocationCoordinate2D(latitude: road.latitudes[segment + 1], longitude: road.longitudes[segment + 1])
                        let off = DashRoute.project(coordinate, onto: a, b).meters
                        if off <= matchMeters, off < (best?.off ?? .greatestFiniteMagnitude) { best = (roadIndex, off) }
                    }
                }
            }
            return best?.road
        }
    }

    /// A road seen for one or two points between the same road on both sides is a crossing street,
    /// not where we were.
    static func smooth(_ roads: [Int?]) -> [Int?] {
        var result = roads
        var index = 1
        while index < result.count - 1 {
            var end = index
            while end < result.count, result[end] == result[index] { end += 1 }
            let before = result[index - 1]
            if end < result.count, end - index <= 2, before == result[end], before != result[index] {
                for fill in index ..< end { result[fill] = before }
            }
            index = end
        }
        return result
    }

    private static func distance(_ a: TripPoint, _ b: TripPoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
