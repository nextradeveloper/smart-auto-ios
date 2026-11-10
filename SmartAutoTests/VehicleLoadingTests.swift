import UIKit
import XCTest
@testable import SmartAuto

@MainActor
final class VehicleLoadingTests: XCTestCase {
    private let session = ZontesSession(account: "test", userCode: "test", signCode: "",
                                        accessToken: "test", tokenTime: "", carCode: "test",
                                        mcuID: "", imsi: "", isOwner: true)

    private var snapshot: VehicleSnapshot {
        VehicleSnapshot(carCode: "test", mcuID: "", name: "368G", remarkName: "",
                        imageURL: nil, isOnline: true, isLocked: nil, fuelPercent: 75,
                        rangeKilometers: 200, batteryVoltage: nil, frontTireKPa: nil,
                        rearTireKPa: nil, maintenanceKilometers: nil, satelliteCount: nil,
                        updatedAt: "", location: nil)
    }

    func testForegroundAndBackgroundRefreshDoNotOverlap() async {
        let started = expectation(description: "Request started")
        var requests = 0
        var completion: CheckedContinuation<VehicleSnapshot, Error>?
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            requests += 1
            return try await withCheckedThrowingContinuation {
                completion = $0
                started.fulfill()
            }
        }
        let first = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isBusy)
        await model.refreshQuietly()
        await model.refresh()
        XCTAssertEqual(requests, 1)
        completion?.resume(returning: snapshot)
        await first.value
        XCTAssertEqual(model.vehicle, snapshot)
        XCTAssertFalse(model.isBusy)
    }

    func testBackgroundRefreshAlsoBlocksDuplicateForegroundRequest() async {
        let started = expectation(description: "Background request started")
        var requests = 0
        var completion: CheckedContinuation<VehicleSnapshot, Error>?
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            requests += 1
            return try await withCheckedThrowingContinuation {
                completion = $0
                started.fulfill()
            }
        }
        let first = Task { await model.refreshQuietly() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(model.isBusy)
        await model.refresh()
        await model.refreshQuietly()
        XCTAssertEqual(requests, 1)
        completion?.resume(returning: snapshot)
        await first.value
        XCTAssertEqual(model.vehicle, snapshot)
    }

    func testLogoutIgnoresLateVehicleResponse() async {
        let started = expectation(description: "Request started")
        var completion: CheckedContinuation<VehicleSnapshot, Error>?
        let model = ZontesAppModel(session: session, automaticallyRefresh: false, sessionClearer: {}) { _ in
            // Deliberately ignore cancellation to simulate an already completed network response.
            try await withCheckedThrowingContinuation {
                completion = $0
                started.fulfill()
            }
        }
        let request = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        model.logout()
        completion?.resume(returning: snapshot)
        await request.value
        XCTAssertNil(model.session)
        XCTAssertNil(model.vehicle)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isBusy)
    }

    func testFailedRefreshKeepsExistingDataAndCanRetry() async {
        var requests = 0
        let expected = snapshot
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            requests += 1
            if requests == 2 { throw URLError(.notConnectedToInternet) }
            return expected
        }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(model.vehicle, expected)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isBusy)
        await model.refresh()
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(model.vehicle, expected)
    }

    func testQuietFailureDoesNotShowAnAlert() async {
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await model.refreshQuietly()
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isBusy)
    }

    func testAuthenticationFailureReturnsToLoginEvenForQuietRefresh() async {
        var sessionWasCleared = false
        let model = ZontesAppModel(session: session, automaticallyRefresh: false,
                                   sessionClearer: { sessionWasCleared = true }) { _ in
            throw ZontesError.authenticationRequired
        }
        await model.refreshQuietly()
        XCTAssertTrue(sessionWasCleared)
        XCTAssertNil(model.session)
        XCTAssertNil(model.vehicle)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isBusy)
    }

    func testNetworkFailureKeepsSessionForRetry() async {
        var sessionWasCleared = false
        let model = ZontesAppModel(session: session, automaticallyRefresh: false,
                                   sessionClearer: { sessionWasCleared = true }) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await model.refresh()
        XCTAssertFalse(sessionWasCleared)
        XCTAssertEqual(model.session, session)
        XCTAssertFalse(model.hasNoVehicle)
    }

    func testMissingVehicleHasSeparateEmptyStateAndCanRecover() async {
        var requests = 0
        let expected = snapshot
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            requests += 1
            if requests == 1 { throw ZontesError.missingVehicle }
            return expected
        }
        await model.refresh()
        XCTAssertTrue(model.hasNoVehicle)
        XCTAssertEqual(model.session, session)
        XCTAssertNil(model.message)
        await model.refresh()
        XCTAssertFalse(model.hasNoVehicle)
        XCTAssertEqual(model.vehicle, expected)
    }

    func testOnlyAuthenticatedRejectionRequiresSigningInAgain() {
        XCTAssertEqual(ZontesAPI.responseError(statusCode: 401, authenticated: true), .authenticationRequired)
        XCTAssertEqual(ZontesAPI.responseError(statusCode: 403, authenticated: true), .authenticationRequired)
        XCTAssertNil(ZontesAPI.responseError(statusCode: 503, authenticated: true))
        XCTAssertNil(ZontesAPI.responseError(statusCode: 401, authenticated: false))
        XCTAssertNil(ZontesAPI.responseError(statusCode: 200, authenticated: true))
    }

    func testMissingVehicleDoesNotRestoreOldDashboardAfterOfflineRetry() async {
        var requests = 0
        let expected = snapshot
        let model = ZontesAppModel(session: session, automaticallyRefresh: false) { _ in
            requests += 1
            switch requests {
            case 1: return expected
            case 2: throw ZontesError.missingVehicle
            default: throw URLError(.notConnectedToInternet)
            }
        }
        await model.refresh()
        XCTAssertNotNil(model.vehicle)
        await model.refresh()
        XCTAssertTrue(model.hasNoVehicle)
        XCTAssertNil(model.vehicle)
        await model.refresh()
        XCTAssertTrue(model.hasNoVehicle)
        XCTAssertNil(model.vehicle)
        XCTAssertEqual(model.session, session)
    }

    func testArtworkDownsamplingBoundsDecodedPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800), format: format).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        }
        let data = try XCTUnwrap(source.pngData())
        let thumbnail = try VehicleArtworkStore.decode(data, maxPixelSize: 240)
        let decoded = try XCTUnwrap(thumbnail.cgImage)
        XCTAssertEqual(decoded.width, 240)
        XCTAssertEqual(decoded.height, 120)
    }

    func testInvalidArtworkFallsBackThroughErrorPath() {
        XCTAssertThrowsError(try VehicleArtworkStore.decode(Data("not an image".utf8), maxPixelSize: 240))
    }
}
