import CoreLocation
import XCTest
@testable import SmartAuto

final class RideTests: XCTestCase {
    /// Full to full: odometer difference over the litres put in since, the first full fill only
    /// starting the count; a part fill in between adds its litres.
    func testKilometresPerLitre() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = FuelFill(date: start, liters: 10, total: 380, odometer: 1000, full: true, fuel: "95")
        let part = FuelFill(date: start.addingTimeInterval(day), liters: 5, total: 190, odometer: nil, full: false, fuel: "95")
        let second = FuelFill(date: start.addingTimeInterval(2 * day), liters: 5, total: 190, odometer: 1300, full: true, fuel: "95")
        let stats = FuelStats([second, first, part])
        XCTAssertEqual(stats.kmPerLiter[second.id] ?? 0, 30, accuracy: 0.001)
        XCTAssertNil(stats.kmPerLiter[first.id])
        XCTAssertEqual(stats.overallKmPerLiter ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(stats.bahtPerKm ?? 0, 380.0 / 300, accuracy: 0.001)
    }

    /// Two minutes north at 10 m/s make a 1.2 km trip; ten minutes parked with GPS wandering add nothing.
    func testTripCountsOnlyMoving() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var builder = TripBuilder()
        var coordinate = CLLocationCoordinate2D(latitude: 13.0, longitude: 100.0)
        for second in 0 ... 120 {
            builder.add(fix(coordinate, speed: 10, at: time.addingTimeInterval(Double(second))))
            coordinate.latitude += 10 / 110_540.0
        }
        for second in 1 ... 600 {
            let wander = CLLocationCoordinate2D(latitude: coordinate.latitude + Double(second % 3) * 4 / 110_540.0,
                                                longitude: coordinate.longitude)
            builder.add(fix(wander, speed: 0, at: time.addingTimeInterval(120 + Double(second))))
        }
        let trip = builder.finish()
        XCTAssertEqual(trip?.summary.distance ?? 0, 1200, accuracy: 15)
        XCTAssertEqual(trip?.summary.movingTime ?? 0, 120, accuracy: 1)
        XCTAssertEqual(trip?.summary.maxSpeed ?? 0, 10, accuracy: 0.01)
        XCTAssertGreaterThan(trip?.points.count ?? 0, 50)
    }

    /// Walking pace never starts a trip.
    func testSlowDoesNotStartATrip() {
        var builder = TripBuilder()
        builder.add(fix(CLLocationCoordinate2D(latitude: 13, longitude: 100), speed: 1.5, at: Date()))
        XCTAssertNil(builder.summary)
    }

    func testAlerts() {
        var vehicle = DashScene.Vehicle(fuelPercent: 30, rangeKm: 50)
        XCTAssertEqual(RideAlerts.alert(for: vehicle, distanceAhead: 45_000)?.text, "น้ำมันอาจไม่พอ")
        XCTAssertNil(RideAlerts.alert(for: vehicle, distanceAhead: 20_000))
        vehicle.fuelPercent = 12
        XCTAssertEqual(RideAlerts.alert(for: vehicle, distanceAhead: nil)?.critical, false)
        vehicle.rearTireKPa = 150
        let tyre = RideAlerts.alert(for: vehicle, distanceAhead: nil)
        XCTAssertEqual(tyre?.text, "ลมยางหลัง 150 kPa")
        XCTAssertEqual(tyre?.critical, true)
    }

    /// 120 km of range on a 200 km route: look for fuel 90 km in (three quarters of the range).
    func testFuelStopTarget() {
        XCTAssertEqual(FuelPlanner.target(routeDistance: 200_000, rangeMeters: 120_000), 90_000, accuracy: 1)
        XCTAssertEqual(FuelPlanner.target(routeDistance: 200_000, rangeMeters: 20_000), 1000, accuracy: 1)
    }

    /// 72 km/h turning at 0.3 rad/s: about 31 degrees.
    func testLeanFromSpeedAndTurnRate() {
        XCTAssertEqual(LeanMeter.lean(speed: 20, yawRate: 0.3), 31.4, accuracy: 0.2)
        XCTAssertEqual(LeanMeter.lean(speed: 20, yawRate: -0.3), -31.4, accuracy: 0.2)
    }

    func testSpeedLimitTags() {
        XCTAssertEqual(TripRoads.limit(["maxspeed": "80"]), 80)
        XCTAssertEqual(TripRoads.limit(["maxspeed": "90", "maxspeed:motorcycle": "70"]), 70)
        XCTAssertEqual(TripRoads.limit(["maxspeed": "TH:urban"]), 80)
        XCTAssertEqual(TripRoads.limit(["maxspeed": "30 mph"]), 48)
        XCTAssertNil(TripRoads.limit(["maxspeed": "signals"]))
        XCTAssertEqual(TripRoads.name(["name:th": "ถนนพหลโยธิน", "ref": "1"]), "ถนนพหลโยธิน (ทล.1)")
        XCTAssertEqual(TripRoads.name(["ref": "3215"]), "ทางหลวง 3215")
    }

    /// 15 s at 108 km/h on an 80 road, then 15 s at 72: one stretch over the limit, on that road.
    func testSpeedingOnARoad() {
        let road = MappedRoad(name: "ถนนทดสอบ", limit: 80, latitudes: [13.0, 13.02], longitudes: [100.0, 100.0])
        var points: [TripPoint] = []
        var latitude = 13.0
        for second in 0 ..< 30 {
            let speed = second < 15 ? 30.0 : 20.0
            points.append(TripPoint(latitude: latitude, longitude: 100.0, time: Double(second), speed: speed))
            latitude += speed / 110_540
        }
        let analysis = TripRoads.analyze(points, roads: [road], assumedLimit: 90)
        XCTAssertEqual(analysis.speeding.count, 1)
        XCTAssertEqual(analysis.speeding.first?.road, "ถนนทดสอบ")
        XCTAssertEqual(analysis.speeding.first?.limit, 80)
        XCTAssertEqual((analysis.speeding.first?.maxSpeed ?? 0) * 3.6, 108, accuracy: 0.1)
        XCTAssertEqual(analysis.roads.first?.name, "ถนนทดสอบ")
        XCTAssertEqual(analysis.roads.first?.distance ?? 0, 15 * 30 + 15 * 20 - 20, accuracy: 40)
    }

    /// One point on a crossing street between two on the main road belongs to the main road.
    func testCrossingStreetIsSmoothedOut() {
        XCTAssertEqual(TripRoads.smooth([0, 0, 1, 0, 0]), [0, 0, 0, 0, 0])
        XCTAssertEqual(TripRoads.smooth([0, 0, 1, 1, 1, 1]), [0, 0, 1, 1, 1, 1])
    }

    func testSpeedCameras() {
        let json = """
        {"elements":[{"type":"node","id":101,"lat":13.75,"lon":100.5,"tags":{"highway":"speed_camera","maxspeed":"90","direction":"NE"}},
                     {"type":"node","id":102,"lat":13.76,"lon":100.51,"tags":{"highway":"speed_camera"}}]}
        """
        let cameras = SpeedCameraSource.parse(Data(json.utf8))
        XCTAssertEqual(cameras.count, 2)
        XCTAssertEqual(cameras.first?.limit, 90)
        XCTAssertEqual(cameras.first?.direction, 45)
        XCTAssertNil(cameras.last?.limit)
        XCTAssertEqual(SpeedCameraSource.direction("270;90"), 270)
        XCTAssertNil(SpeedCameraSource.direction("forward"))
    }

    private func fix(_ coordinate: CLLocationCoordinate2D, speed: Double, at time: Date) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                   course: 0, speed: speed, timestamp: time)
    }
}
