import XCTest
@testable import SmartAuto

final class DataManagementTests: XCTestCase {
    func testRemovingHistoryDirectoryPreservesSiblingFilesAndCanRepeat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trips = root.appendingPathComponent("Trips", isDirectory: true)
        let sibling = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("trip".utf8).write(to: trips.appendingPathComponent("points.json"))
        try Data("settings".utf8).write(to: sibling)

        try AppDataFiles.removeIfPresent(trips)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trips.path))
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "settings")
        XCTAssertNoThrow(try AppDataFiles.removeIfPresent(trips))
    }

    func testClearingParkingDoesNotRemoveAccountOrPreferences() throws {
        let suite = "SmartAutoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1]), forKey: "parkedSpot.vehicleA")
        defaults.set(Data([2]), forKey: "parkedSpot.vehicleB")
        defaults.set("account", forKey: "account")
        defaults.set(true, forKey: "dash.autoConnect")
        defaults.set("style", forKey: "vehicleStyle.vehicleA")

        ParkedSpotStore.clearAll(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "parkedSpot.vehicleA"))
        XCTAssertNil(defaults.object(forKey: "parkedSpot.vehicleB"))
        XCTAssertEqual(defaults.string(forKey: "account"), "account")
        XCTAssertTrue(defaults.bool(forKey: "dash.autoConnect"))
        XCTAssertEqual(defaults.string(forKey: "vehicleStyle.vehicleA"), "style")
    }

    func testHistoryExportPreservesTripCoordinatesAndFuelWithoutAccountData() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = TripSummary(id: UUID(), start: date, end: date.addingTimeInterval(120),
                                  distance: 1000, movingTime: 120, maxSpeed: 15,
                                  maxLeanLeft: 10, maxLeanRight: 12, startName: "Start", endName: "End")
        let point = TripPoint(latitude: 13.7, longitude: 100.5, time: 30, speed: 10)
        let fill = FuelFill(date: date, liters: 5, total: 200, odometer: 1000, fuel: "95")
        let export = HistoryExport(version: 1, exportedAt: date,
                                   trips: [.init(summary: summary, points: [point])], fuel: [fill])
        let data = try export.data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryExport.self, from: data)
        XCTAssertEqual(decoded.trips.first?.summary, summary)
        XCTAssertEqual(decoded.trips.first?.points, [point])
        XCTAssertEqual(decoded.fuel, [fill])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["version", "exportedAt", "trips", "fuel"]))
    }
}

@MainActor
final class ConnectionDiagnosticsTests: XCTestCase {
    func testHTTPResponseProvesReachabilityEvenWhenAccountIsNotAuthorized() {
        for code in [200, 301, 401, 403, 405] {
            guard case .passed = ConnectionDiagnostics.cloudResult(statusCode: code) else {
                XCTFail("HTTP \(code) should establish server reachability")
                continue
            }
        }
    }

    func testServerFailureOrMissingResponseIsNotShownAsHealthy() {
        let codes: [Int?] = [nil, 500, 503]
        for code in codes {
            guard case .failed = ConnectionDiagnostics.cloudResult(statusCode: code) else {
                XCTFail("Missing or failed response must not pass")
                continue
            }
        }
    }
}
