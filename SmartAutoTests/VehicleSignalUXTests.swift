import XCTest
@testable import SmartAuto

@MainActor
final class VehicleSignalUXTests: XCTestCase {
    func testSoundSequenceRelocksBeforeCompleting() async throws {
        var commands: [VehicleCommand] = []
        try await VehicleSignalSequence.run(locked: true, send: { commands.append($0) }, pause: { _ in })
        XCTAssertEqual(commands, [.unlock, .lock])
    }

    func testLostUnlockAcknowledgementStillAttemptsToRelock() async {
        var commands: [VehicleCommand] = []
        do {
            try await VehicleSignalSequence.run(locked: nil, send: { command in
                commands.append(command)
                if command == .unlock { throw ZontesError.commandTimedOut }
            }, pause: { _ in })
            XCTFail("Unconfirmed sound action must remain a failure")
        } catch {
            XCTAssertEqual(error as? ZontesError, .commandTimedOut)
        }
        XCTAssertEqual(commands, [.unlock, .lock])
    }

    func testRelockRetriesAndDoesNotReportSuccessWhenAllAttemptsFail() async {
        var commands: [VehicleCommand] = []
        do {
            try await VehicleSignalSequence.run(locked: true, send: { command in
                commands.append(command)
                if command == .lock { throw ZontesError.commandConnectionClosed }
            }, pause: { _ in })
            XCTFail("Failed relocking must not be reported as success")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(commands, [.unlock, .lock, .lock, .lock])
    }

    func testAlreadyUnlockedVehicleIsOnlyLocked() async throws {
        var commands: [VehicleCommand] = []
        try await VehicleSignalSequence.run(locked: false, send: { commands.append($0) }, pause: { _ in })
        XCTAssertEqual(commands, [.lock])
    }
}
