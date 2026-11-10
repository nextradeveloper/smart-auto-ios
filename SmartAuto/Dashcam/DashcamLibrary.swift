import Combine
import Foundation

/// Advance by the raw page size, but stop if a camera repeats a page instead of paging.
struct DashcamPagination {
    private(set) var index = 0
    private(set) var hasMore = true

    mutating func append<Item: Identifiable>(_ page: [Item], to items: inout [Item], pageSize: Int) {
        var known = Set(items.map(\.id))
        let fresh = page.filter { known.insert($0.id).inserted }
        items.append(contentsOf: fresh)
        index += page.count
        hasMore = page.count >= pageSize && !fresh.isEmpty
    }
}

enum DashcamLabels {
    static func newestFirst(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    /// Only use dates actually present in a filename; undated photos keep an explicit fallback.
    static func dateKey(in name: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\d)(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?:[T_ -]?\d{6})?(?!\d)"#),
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let year = Range(match.range(at: 1), in: name),
              let month = Range(match.range(at: 2), in: name),
              let day = Range(match.range(at: 3), in: name) else { return nil }
        let key = "\(name[year])-\(name[month])-\(name[day])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: key), formatter.string(from: date) == key else { return nil }
        return key
    }

    static func date(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 8, let key = dateKey(in: digits) else { return raw }
        return key
    }
}

@MainActor
final class DashcamVideoLibrary: ObservableObject {
    @Published private(set) var dates: [String] = []
    @Published private(set) var times: [String] = []
    @Published private(set) var date = ""
    @Published private(set) var time = ""
    @Published private(set) var videos: [DashcamClient.Video] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var failure: String?
    @Published private(set) var hasMore = false
    private let client: DashcamServing
    private var camera: DashcamClient.Camera?
    private var request = UUID()
    private var loaded = false
    private var pagination = DashcamPagination()

    init(client: DashcamServing = DashcamClient()) { self.client = client }

    func open(_ camera: DashcamClient.Camera, refresh: Bool = false) async {
        if self.camera == camera && loaded && !refresh { return }
        let sameCamera = self.camera == camera
        self.camera = camera
        let id = begin(clear: !sameCamera)
        if !sameCamera { dates = []; times = []; date = ""; time = "" }
        defer { finish(id) }
        do {
            let available = try await client.dates(camera)
            guard current(id) else { return }
            dates = DashcamLabels.newestFirst(available)
            guard !dates.isEmpty else { videos = []; times = []; date = ""; time = ""; loaded = true; return }
            let day = dates.contains(date) ? date : dates[0]
            try await loadDay(day, camera: camera, request: id)
            if current(id) { loaded = true }
        } catch { fail(error, id) }
    }

    func selectDate(_ date: String) async {
        guard let camera, dates.contains(date) else { return }
        let id = begin(clear: true)
        self.date = date
        time = ""
        times = []
        defer { finish(id) }
        do {
            try await loadDay(date, camera: camera, request: id)
            if current(id) { loaded = true }
        }
        catch { fail(error, id) }
    }

    func selectTime(_ time: String) async {
        guard let camera, times.contains(time) else { return }
        let id = begin(clear: true)
        self.time = time
        defer { finish(id) }
        do {
            try await loadVideos(camera, request: id)
            if current(id) { loaded = true }
        }
        catch { fail(error, id) }
    }

    func loadMore() async {
        guard let camera, !loading, !loadingMore, pagination.hasMore, !time.isEmpty else { return }
        let id = request
        loadingMore = true
        failure = nil
        defer { if request == id { loadingMore = false } }
        do { try await loadVideos(camera, request: id) }
        catch { fail(error, id) }
    }

    private func loadDay(_ day: String, camera: DashcamClient.Camera, request id: UUID) async throws {
        let previousTime = time
        let available = try await client.times(camera, date: day)
        guard current(id) else { return }
        date = day
        times = DashcamLabels.newestFirst(available)
        guard !times.isEmpty else { videos = []; time = ""; return }
        time = times.contains(previousTime) ? previousTime : times[0]
        videos = []
        try await loadVideos(camera, request: id)
    }

    private func loadVideos(_ camera: DashcamClient.Camera, request id: UUID) async throws {
        let page = try await client.videos(camera, date: date, time: time, index: pagination.index)
        guard current(id) else { return }
        pagination.append(page, to: &videos, pageSize: DashcamClient.videoPageSize)
        hasMore = pagination.hasMore
    }

    private func begin(clear: Bool) -> UUID {
        request = UUID()
        loaded = false
        loading = true
        loadingMore = false
        failure = nil
        pagination = DashcamPagination()
        hasMore = false
        if clear { videos = [] }
        return request
    }
    private func current(_ id: UUID) -> Bool { request == id && !Task.isCancelled }
    private func finish(_ id: UUID) { if request == id { loading = false } }
    private func fail(_ error: Error, _ id: UUID) {
        if current(id) && !(error is CancellationError) { failure = error.localizedDescription }
    }
}

@MainActor
final class DashcamPhotoLibrary: ObservableObject {
    @Published private(set) var pictures: [DashcamClient.Picture] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var hasMore = true
    private let client: DashcamServing
    private var pagination = DashcamPagination()
    private var request = UUID()
    private var loaded = false
    private var retryRefresh = false

    init(client: DashcamServing = DashcamClient()) { self.client = client }

    func load(refresh: Bool = false) async {
        guard !loading else { return }
        if !refresh && (loaded && !pagination.hasMore) { return }
        request = UUID()
        let id = request
        loading = true
        failure = nil
        retryRefresh = refresh
        defer { if request == id { loading = false } }
        do {
            let page = try await client.pictures(index: refresh ? 0 : pagination.index)
            guard request == id, !Task.isCancelled else { return }
            if refresh { pictures = []; pagination = DashcamPagination() }
            pagination.append(page, to: &pictures, pageSize: DashcamClient.picturePageSize)
            hasMore = pagination.hasMore
            loaded = true
        } catch {
            guard request == id, !Task.isCancelled, !(error is CancellationError) else { return }
            failure = error.localizedDescription
        }
    }

    func open() async { if !loaded { await load() } }
    func retry() async { await load(refresh: retryRefresh) }

    /// Search older metadata without fetching image bytes; cancellation stops the current request.
    func searchEarlier(matching predicate: (DashcamClient.Picture) -> Bool) async {
        while hasMore && !Task.isCancelled && !pictures.contains(where: predicate) {
            let previousCount = pictures.count
            await load()
            if failure != nil || pictures.count == previousCount { return }
        }
    }
}
