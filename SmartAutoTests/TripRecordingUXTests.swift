import CoreLocation
import XCTest
@testable import SmartAuto

final class TripRecordingUXTests: XCTestCase {
    @MainActor
    func testTurningRecordingOffRejectsNextGPSFixAndTurningOnStartsNewSegment() throws {
        let suite = "TripRecordingUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DashSettings.recordTripsKey)
        let recorder = TripRecorder(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(at date: Date) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 13, longitude: 100),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       course: 0, speed: 12, timestamp: date)
        }
        recorder.begin()
        recorder.add(fix(at: start))
        XCTAssertNotNil(recorder.current)

        defaults.set(false, forKey: DashSettings.recordTripsKey)
        recorder.add(fix(at: start.addingTimeInterval(1)))
        XCTAssertNil(recorder.current)

        defaults.set(true, forKey: DashSettings.recordTripsKey)
        let restarted = start.addingTimeInterval(2)
        recorder.add(fix(at: restarted))
        XCTAssertEqual(recorder.current?.start, restarted)
        recorder.end()
        XCTAssertNil(recorder.current)
    }

    func testPreferenceChangesDuringOneDashSessionStopAndRestartRecording() {
        var recording = false
        let choices: [(running: Bool, enabled: Bool)] = [
            (false, false), (true, false), (true, true),
            (true, false), (true, false), (true, true), (false, true),
        ]
        let actions = choices.map { choice -> TripRecordingGate.Action in
            let action = TripRecordingGate.action(isRecording: recording,
                                                   dashRunning: choice.running, enabled: choice.enabled)
            switch action {
            case .start: recording = true
            case .stop: recording = false
            case .unchanged: break
            }
            return action
        }
        XCTAssertEqual(actions, [.unchanged, .unchanged, .start, .stop, .unchanged, .start, .stop])
        XCTAssertFalse(recording)
    }

    func testDisabledRecordingCannotStartWhenDashRestarts() {
        XCTAssertEqual(TripRecordingGate.action(isRecording: false, dashRunning: true, enabled: false), .unchanged)
        XCTAssertEqual(TripRecordingGate.action(isRecording: true, dashRunning: true, enabled: false), .stop)
        XCTAssertEqual(TripRecordingGate.action(isRecording: false, dashRunning: false, enabled: true), .unchanged)
    }
}

@MainActor
final class DashCacheMaintenanceUXTests: XCTestCase {
    func testMaintenanceBlocksScreenAndNavigationUntilCleanupCompletes() async throws {
        let service = DashScreenService()
        try await service.withCacheMaintenance {
            XCTAssertTrue(service.isMaintainingCache)
            service.start()
            XCTAssertFalse(service.isRunning)
            let destination = DashDestination(name: "Test", subtitle: "",
                                              coordinate: CLLocationCoordinate2D(latitude: 13, longitude: 100))
            service.startNavigation(to: destination, legs: [])
            XCTAssertFalse(service.navigator.isNavigating)
            await Task.yield()
            XCTAssertTrue(service.isMaintainingCache)
        }
        XCTAssertFalse(service.isMaintainingCache)
        XCTAssertFalse(service.isRunning)
    }

    func testFailedCleanupAlwaysReleasesMaintenanceGate() async {
        enum CleanupError: Error { case expected }
        let service = DashScreenService()
        do {
            try await service.withCacheMaintenance { throw CleanupError.expected }
            XCTFail("Cleanup error should propagate")
        } catch CleanupError.expected {
            XCTAssertFalse(service.isMaintainingCache)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNestedMaintenanceCannotEnterWhileCleanupIsSuspended() async throws {
        let service = DashScreenService()
        var nestedCleanupRan = false
        try await service.withCacheMaintenance {
            await Task.yield()
            do {
                try await service.withCacheMaintenance { nestedCleanupRan = true }
                XCTFail("Nested maintenance should be rejected")
            } catch {
                XCTAssertTrue(service.isMaintainingCache)
            }
        }
        XCTAssertFalse(nestedCleanupRan)
        XCTAssertFalse(service.isMaintainingCache)
    }
}
