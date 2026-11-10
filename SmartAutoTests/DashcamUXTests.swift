import XCTest
@testable import SmartAuto

final class DashcamMediaTests: XCTestCase {
    func testPagesDeduplicateAndStopWhenCameraRepeatsPage() {
        var paging = DashcamPagination()
        let page = [picture("a.jpg"), picture("b.jpg")]
        var pictures: [DashcamClient.Picture] = []
        paging.append(page, to: &pictures, pageSize: 2)
        XCTAssertEqual(paging.index, 2)
        XCTAssertTrue(paging.hasMore)
        paging.append(page, to: &pictures, pageSize: 2)
        XCTAssertEqual(pictures, page)
        XCTAssertEqual(paging.index, 4)
        XCTAssertFalse(paging.hasMore)
    }

    func testPhotoDatesAreTakenFromNamesAndInvalidDatesStayUnknown() {
        XCTAssertEqual(DashcamLabels.dateKey(in: "IMG_20261110_142233.jpg"), "2026-11-10")
        XCTAssertEqual(DashcamLabels.dateKey(in: "20261110142233.jpg"), "2026-11-10")
        XCTAssertEqual(DashcamLabels.dateKey(in: "2026-11-10_photo.jpg"), "2026-11-10")
        XCTAssertNil(DashcamLabels.dateKey(in: "IMG_20260230.jpg"))
        XCTAssertNil(DashcamLabels.dateKey(in: "photo42.jpg"))
        XCTAssertEqual(DashcamLabels.newestFirst(["9", "14", "14"]), ["14", "9"])
    }

    func testMediaURLsSupportCameraHostAndRelativePaths() {
        XCTAssertEqual(DashcamClient.url("192.168.3.1:7686/video/a.mp4")?.absoluteString,
                       "http://192.168.3.1:7686/video/a.mp4")
        XCTAssertEqual(DashcamClient.url("/photo/a b.jpg")?.absoluteString,
                       "http://192.168.3.1:7686/photo/a%20b.jpg")
        XCTAssertEqual(DashcamClient.url("photo/a.jpg")?.absoluteString,
                       "http://192.168.3.1:7686/photo/a.jpg")
        XCTAssertNil(DashcamClient.url("file:///photo/a.jpg"))
    }

    func testPlaybackSeekNeverLeavesKnownTimeline() {
        XCTAssertEqual(DashcamPlayback.seekTarget(current: 3, offset: -10, duration: 60), 0)
        XCTAssertEqual(DashcamPlayback.seekTarget(current: 55, offset: 10, duration: 60), 60)
        XCTAssertEqual(DashcamPlayback.seekTarget(current: .nan, offset: 10, duration: .nan), 10)
    }

    private func picture(_ name: String) -> DashcamClient.Picture {
        DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent(name))
    }
}

@MainActor
private final class DashcamStub: DashcamServing {
    var calls: [String] = []
    var suspendFrontOnce = false
    var onFrontWait: (() -> Void)?
    var heldFront: CheckedContinuation<[String], Error>?
    var photoReplies: [Result<[DashcamClient.Picture], Error>] = []

    func dates(_ camera: DashcamClient.Camera) async throws -> [String] {
        calls.append("dates:\(camera.rawValue)")
        if camera == .front && suspendFrontOnce {
            suspendFrontOnce = false
            return try await withCheckedThrowingContinuation {
                heldFront = $0
                onFrontWait?()
            }
        }
        return camera == .front ? ["2026-11-09", "2026-11-10"] : ["2026-11-08"]
    }
    func times(_ camera: DashcamClient.Camera, date: String) async throws -> [String] {
        calls.append("times:\(camera.rawValue):\(date)")
        return ["09", "14"]
    }
    func videos(_ camera: DashcamClient.Camera, date: String, time: String, index: Int) async throws -> [DashcamClient.Video] {
        calls.append("videos:\(camera.rawValue):\(date):\(time):\(index)")
        return [.init(title: camera.rawValue, name: "clip.mp4",
                      playURL: DashcamClient.base.appendingPathComponent("\(camera.rawValue).mp4"), thumbURL: nil)]
    }
    func pictures(index: Int) async throws -> [DashcamClient.Picture] {
        calls.append("pictures:\(index)")
        return try photoReplies.removeFirst().get()
    }
}

@MainActor
final class DashcamLibraryTests: XCTestCase {
    func testFirstLoadFetchesOnlyLatestSelectedDayAndTime() async {
        let stub = DashcamStub()
        let library = DashcamVideoLibrary(client: stub)
        await library.open(.front)
        XCTAssertEqual(stub.calls, ["dates:front", "times:front:2026-11-10", "videos:front:2026-11-10:14:0"])
        XCTAssertEqual(library.date, "2026-11-10")
        XCTAssertEqual(library.time, "14")
        XCTAssertFalse(library.loading)
        await library.open(.front)
        XCTAssertEqual(stub.calls.count, 3, "Returning from player must preserve the library without reloading")
    }

    func testLateFrontResponseCannotReplaceRearCameraSelection() async {
        let stub = DashcamStub()
        let started = expectation(description: "Front request held")
        stub.suspendFrontOnce = true
        stub.onFrontWait = { started.fulfill() }
        let library = DashcamVideoLibrary(client: stub)
        let front = Task { await library.open(.front) }
        await fulfillment(of: [started], timeout: 2)
        await library.open(.rear)
        stub.heldFront?.resume(returning: ["2026-11-10"])
        await front.value
        XCTAssertEqual(library.date, "2026-11-08")
        XCTAssertEqual(library.videos.first?.title, "rear")
    }

    func testCancelledFirstLoadCanBeOpenedAgain() async {
        let stub = DashcamStub()
        let started = expectation(description: "First request held")
        stub.suspendFrontOnce = true
        stub.onFrontWait = { started.fulfill() }
        let library = DashcamVideoLibrary(client: stub)
        let first = Task { await library.open(.front) }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        stub.heldFront?.resume(returning: ["2026-11-10"])
        await first.value
        await library.open(.front)
        XCTAssertEqual(library.videos.first?.title, "front")
        XCTAssertEqual(stub.calls.filter { $0 == "dates:front" }.count, 2)
    }

    func testFailedPhotoRefreshRetriesFirstPageAndKeepsOlderPagingUsable() async {
        let stub = DashcamStub()
        let first = (0..<100).map { DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent("old\($0).jpg")) }
        let refreshed = (0..<100).map { DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent("new\($0).jpg")) }
        let older = DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent("older.jpg"))
        stub.photoReplies = [.success(first), .failure(URLError(.timedOut)), .success(refreshed), .success([older])]
        let library = DashcamPhotoLibrary(client: stub)
        await library.open()
        await library.load(refresh: true)
        XCTAssertEqual(library.pictures, first)
        XCTAssertNotNil(library.failure)
        await library.retry()
        XCTAssertEqual(library.pictures, refreshed)
        await library.load()
        XCTAssertEqual(stub.calls, ["pictures:0", "pictures:0", "pictures:0", "pictures:100"])
        XCTAssertEqual(library.pictures.last, older)
        XCTAssertFalse(library.hasMore)
    }

    func testSearchingEarlierPhotosStopsAsSoonAsMatchingMetadataIsFound() async {
        let stub = DashcamStub()
        let recent = (0..<100).map { DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent("recent\($0).jpg")) }
        let older = (0..<100).map { DashcamClient.Picture(url: DashcamClient.base.appendingPathComponent("older\($0).jpg")) }
        stub.photoReplies = [.success(recent), .success(older)]
        let library = DashcamPhotoLibrary(client: stub)
        await library.open()
        await library.searchEarlier { $0.name == "older42.jpg" }
        XCTAssertEqual(stub.calls, ["pictures:0", "pictures:100"])
        XCTAssertTrue(library.hasMore, "Finding a match must stop before downloading every metadata page")
        XCTAssertTrue(library.pictures.contains { $0.name == "older42.jpg" })
    }
}
