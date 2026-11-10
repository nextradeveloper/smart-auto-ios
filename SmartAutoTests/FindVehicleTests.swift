import CoreLocation
import XCTest
@testable import SmartAuto

final class FindVehicleTests: XCTestCase {
    func testProximityLevelThresholds() {
        XCTAssertEqual(ProximityLevel(rssi: -45), .veryClose)
        XCTAssertEqual(ProximityLevel(rssi: -62), .veryClose)
        XCTAssertEqual(ProximityLevel(rssi: -63), .near)
        XCTAssertEqual(ProximityLevel(rssi: -74), .near)
        XCTAssertEqual(ProximityLevel(rssi: -75), .medium)
        XCTAssertEqual(ProximityLevel(rssi: -86), .medium)
        XCTAssertEqual(ProximityLevel(rssi: -87), .far)
        XCTAssertNil(ProximityLevel.far.pulseInterval)
        XCTAssertLessThan(ProximityLevel.veryClose.pulseInterval ?? 1, ProximityLevel.near.pulseInterval ?? 0)
    }

    func testParkedSpotPrefersNearbyLockFix() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lock = ParkedSpot(latitude: 13.7563, longitude: 100.5018, horizontalAccuracy: 5, date: start, source: .lock)
        // About 33 m north: Bluetooth dropped while walking away from the parked vehicle.
        let walkedAway = ParkedSpot(latitude: 13.7566, longitude: 100.5018, horizontalAccuracy: 20,
                                    date: start.addingTimeInterval(300), source: .walkAway)
        // About 1.1 km away: the vehicle was ridden after that lock.
        let elsewhere = ParkedSpot(latitude: 13.7663, longitude: 100.5018, horizontalAccuracy: 20,
                                   date: start.addingTimeInterval(1_800), source: .walkAway)
        // A lock saved after the walk-away fix belongs to a later visit.
        let laterLock = ParkedSpot(latitude: 13.7563, longitude: 100.5018, horizontalAccuracy: 5,
                                   date: start.addingTimeInterval(600), source: .lock)

        XCTAssertEqual(ParkedSpot.choose(lock: lock, walkAway: walkedAway), lock)
        XCTAssertEqual(ParkedSpot.choose(lock: lock, walkAway: elsewhere), elsewhere)
        XCTAssertEqual(ParkedSpot.choose(lock: nil, walkAway: walkedAway), walkedAway)
        XCTAssertEqual(ParkedSpot.choose(lock: laterLock, walkAway: walkedAway), walkedAway)
    }

    func testParkedSpotRoundTripsThroughJSON() throws {
        let spot = ParkedSpot(latitude: 13.7563, longitude: 100.5018, horizontalAccuracy: 8,
                              date: Date(timeIntervalSince1970: 1_800_000_000), source: .manual)
        let decoded = try JSONDecoder().decode(ParkedSpot.self, from: JSONEncoder().encode(spot))
        XCTAssertEqual(decoded, spot)
    }

    @MainActor
    func testManualSaveRejectsStaleInaccurateAndFutureLocations() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(accuracy: Double, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 13.7, longitude: 100.5),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(ParkingSpotTracker.isSuitableForManualSave(fix(accuracy: 50, age: 10), now: now))
        XCTAssertFalse(ParkingSpotTracker.isSuitableForManualSave(fix(accuracy: 51, age: 1), now: now))
        XCTAssertFalse(ParkingSpotTracker.isSuitableForManualSave(fix(accuracy: -1, age: 1), now: now))
        XCTAssertFalse(ParkingSpotTracker.isSuitableForManualSave(fix(accuracy: 5, age: 11), now: now))
        XCTAssertFalse(ParkingSpotTracker.isSuitableForManualSave(fix(accuracy: 5, age: -1), now: now))
    }

    @MainActor
    func testManualSaveWithoutVehicleReportsFailure() {
        let tracker = ParkingSpotTracker()
        tracker.saveCurrentLocation()
        guard case let .failed(message) = tracker.manualSaveState else {
            XCTFail("A manual save without a vehicle must explain why it failed")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(tracker.spot)
    }
}
