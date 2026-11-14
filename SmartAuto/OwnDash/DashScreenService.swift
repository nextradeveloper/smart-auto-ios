import CoreLocation
import Foundation
import MapKit
import Network
import UIKit

/// Smart Auto's own screen on the dash: drawn here, encoded on the CPU, kept going behind the lock
/// screen by navigation-grade location updates.
///
/// Screen share records the phone's screen and stops when it locks; this does not record anything.
/// The phone-locked test (2026-11-08) proved the path: SoftwareVideoEncoder + DashSession profile H.
@MainActor
final class DashScreenService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var state: BroadcastState = .idle
    @Published private(set) var message = ""
    @Published private(set) var isMaintainingCache = false
    /// What the dash shows, a few times a second, for the app's own view of it.
    @Published private(set) var preview: CGImage?
    /// For the phone's full-screen map, which repeats the dash's cards.
    @Published private(set) var speedKmh: Int?
    @Published private(set) var vehicle = DashScene.Vehicle()
    private var phoneMapVisible = false

    /// The app is showing the preview; frames are only copied for it while it is visible and the
    /// app is in front.
    var previewEnabled = false {
        didSet { updatePreview() }
    }
    private var appActive = true

    let navigator = DashNavigator()
    let maps = DashMapProvider()
    private let voice = DashVoice()
    private let cameras = SpeedCameraWatch()
    let trips = TripRecorder()
    /// Fetches the bike's fuel, range and tyres from ZONTES' service: at start, then every 3 minutes.
    var refreshVehicleData: (@MainActor () async -> Void)?
    private var sceneTicks = 0

    /// Bike state for the ride card; polled once a second while running.
    var vehicleSource: (@MainActor () -> DashScene.Vehicle)?

    /// The best known position, for searching nearby and routing before the screen is on.
    var lastKnownLocation: CLLocation? { lastLocation ?? locationManager.location }

    private let store = DashSceneStore()
    private let locationManager = CLLocationManager()
    @Published private(set) var lastLocation: CLLocation?
    private var dash: DashSession?
    private var loop: DashFrameLoop?
    private var statusTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Auto connect.
    private var pathMonitor: NWPathMonitor?
    private var onDashWifi = false
    private var bikeConnected = false
    /// Turned off by hand at the bike: not again until it is left (Wi-Fi or Bluetooth gone).
    private var autoSuppressed = false
    private var autoStopTask: Task<Void, Never>?
    private var autoGiveUpTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.headingFilter = 1
        let store = store
        maps.onMap = { store.set(map: $0) }
        navigator.onRoute = { [weak self] route in
            self?.maps.prepare(along: route)
            self?.cameras.prepare(along: route)
        }
        navigator.onAnnounce = { [weak self] text in
            self?.voice.announce(text)
        }
    }

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    // MARK: Screen

    func start() {
        guard !isRunning, !isMaintainingCache else { return }
        let profile = DashProfile.byID(SharedStore.profileID)
        log("Dash screen starting. Profile \(profile.id), Wi-Fi \(DashLocator.wifiAddressDescription()).")
        let size = CGSize(width: profile.fallbackWidth, height: profile.fallbackHeight)
        guard let loop = DashFrameLoop(size: size, store: store, log: { EventLog.record("OWNDASH", $0) }) else {
            log("The software H.264 encoder could not start.")
            setState(.failed, "เริ่มตัวเข้ารหัสภาพไม่ได้")
            return
        }

        startLocation(background: true)
        let dash = DashSession(profile: profile) { EventLog.record("DASH", $0) }
        dash.onEvent = { [weak self, weak loop] event in
            switch event {
            case let .state(newState, text):
                Task { @MainActor in self?.setState(newState, text) }
            case .streamStart, .linkUp, .needKeyFrame, .videoArea:
                loop?.requestKeyFrame()
            }
        }
        loop.onAccessUnit = { [weak dash] accessUnit in dash?.push(accessUnit) }
        loop.onPreview = { [weak self] image in
            Task { @MainActor in self?.preview = image }
        }
        self.loop = loop
        self.dash = dash
        watchPhoneState()
        refreshScene()
        updatePreview()
        if let known = lastKnownLocation {
            maps.update(for: known)
        }
        loop.start()
        dash.start()
        isRunning = true
        trips.begin()
        if let refreshVehicleData { Task { await refreshVehicleData() } }
        setState(.connecting, "กำลังเชื่อมต่อจอรถ")
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshScene() }
        }
    }

    /// `byUser`: the rider pressed ปิด, so auto connect leaves it off until they leave the bike.
    func stop(byUser: Bool = true, reason: String = "by the user") {
        guard isRunning else { return }
        log("Dash screen stopped \(reason) after \(dash?.framesPushed ?? 0) frames.")
        if byUser { autoSuppressed = onDashWifi || bikeConnected }
        autoStopTask?.cancel()
        autoStopTask = nil
        autoGiveUpTask?.cancel()
        autoGiveUpTask = nil
        statusTimer?.invalidate()
        statusTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        loop?.stop()
        dash?.stop()
        loop = nil
        dash = nil
        trips.end()
        navigator.stop()
        cameras.reset()
        store.set(camera: nil)
        maps.reset()
        maps.set(mode: .overview)
        store.set(map: nil)
        store.set(navigation: nil)
        if !phoneMapVisible {
            locationManager.stopUpdatingLocation()
            locationManager.stopUpdatingHeading()
        }
        locationManager.allowsBackgroundLocationUpdates = false
        isRunning = false
        preview = nil
        setState(.stopped, "")
    }

    private func updatePreview() {
        loop?.previewEnabled = previewEnabled && appActive
    }

    /// The phone's full-screen map is open: keep location and the compass going for its cards even
    /// when the dash is off.
    func phoneMap(visible: Bool) {
        guard !visible || !isMaintainingCache else { return }
        phoneMapVisible = visible
        if visible {
            startLocation(background: isRunning)
        } else if !isRunning {
            locationManager.stopUpdatingLocation()
            locationManager.stopUpdatingHeading()
        }
    }

    /// The bike as known now, also while the dash screen is off.
    func currentVehicle() -> DashScene.Vehicle {
        vehicleSource?() ?? vehicle
    }

    /// Asks for location permission if needed and a fresh fix, for search and routing.
    func prepareLocation() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if !isRunning {
            locationManager.requestLocation()
        }
    }

    // MARK: Guidance

    /// Starts guidance, and the dash screen with it if it is not on yet.
    func startNavigation(to destination: DashDestination, stops: [DashDestination] = [], legs: [MKRoute]) {
        guard !isMaintainingCache else { return }
        navigator.start(destination, stops: stops, legs: legs)
        maps.set(mode: .guidance)
        if !isRunning { start() }
        if let lastLocation { maps.update(for: lastLocation) }
        refreshScene()
    }

    func stopNavigation() {
        navigator.stop()
        cameras.reset()
        maps.set(mode: .overview)
        if let lastLocation { maps.update(for: lastLocation) }
        refreshScene()
    }

    /// Hold one gate across all suspension points so auto-connect cannot restart map work
    /// between the usage check and removal of the saved tiles.
    func withCacheMaintenance(_ cleanup: @MainActor () async throws -> Void) async throws {
        guard !isMaintainingCache, !isRunning, !phoneMapVisible, !navigator.isNavigating,
              maps.preparing == nil, !maps.isSavingTiles else {
            throw ZontesError.message("ปิดจอรถ จบการนำทาง และรอให้บันทึกแผนที่เสร็จก่อนล้างแคช")
        }
        isMaintainingCache = true
        defer {
            isMaintainingCache = false
            if onDashWifi || bikeConnected { autoStart(onDashWifi ? "dash Wi-Fi after cache cleanup" : "bike Bluetooth after cache cleanup") }
        }
        try await cleanup()
    }

    // MARK: Auto connect

    /// Like RideScreen: the dash screen turns on by itself when the phone joins the dash's Wi-Fi
    /// (192.168.3.x) or the bike's Bluetooth connects, and off a minute after both are gone, unless
    /// guiding (then it waits for the bike to come back). Call once at launch.
    func startAutoConnect() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.wifiChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "smartauto.dash.wifi"))
        pathMonitor = monitor
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wifiChanged() }
        }
    }

    /// The switch in the app was turned on or off.
    func autoConnectChanged() {
        if DashSettings.autoConnect {
            autoSuppressed = false
            if onDashWifi || bikeConnected { autoStart(onDashWifi ? "dash Wi-Fi" : "bike Bluetooth") }
        } else {
            autoStopTask?.cancel()
            autoStopTask = nil
            autoGiveUpTask?.cancel()
            autoGiveUpTask = nil
        }
    }

    /// The bike's Bluetooth link came up or went down.
    func bikeLink(_ up: Bool) {
        guard up != bikeConnected else { return }
        bikeConnected = up
        if up {
            autoStart("bike Bluetooth")
        } else {
            if !onDashWifi { autoSuppressed = false }
            scheduleAutoStop("bike Bluetooth off")
        }
    }

    static func isDashWifi() -> Bool {
        guard let (address, _) = DashLocator.wifiIPv4() else { return false }
        return address >> 8 == 0xC0A803 // 192.168.3.x, the dash's own access point
    }

    private func wifiChanged() {
        let now = Self.isDashWifi()
        if now != onDashWifi {
            onDashWifi = now
            log(now ? "Phone joined the dash Wi-Fi (\(DashLocator.wifiAddressDescription()))." : "Phone left the dash Wi-Fi.")
            if !now {
                if !bikeConnected { autoSuppressed = false }
                scheduleAutoStop("dash Wi-Fi gone")
            }
        }
        if now { autoStart("dash Wi-Fi") }
    }

    private func autoStart(_ reason: String) {
        guard DashSettings.autoConnect, !isMaintainingCache else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        guard !isRunning, !autoSuppressed else { return }
        let where_ = UIApplication.shared.applicationState == .active ? "in front" : "in background"
        log("Auto connect: starting the dash screen (\(reason)); app \(where_), " +
            "location authorization \(locationManager.authorizationStatus.rawValue).")
        start()
        autoGiveUpTask?.cancel()
        autoGiveUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.autoGiveUpTask = nil
            if self.isRunning, self.state != .streaming, !self.onDashWifi, !self.navigator.isNavigating {
                self.stop(byUser: false, reason: "by auto connect (no dash in 2 minutes)")
            }
        }
    }

    private func scheduleAutoStop(_ reason: String) {
        guard DashSettings.autoConnect, isRunning, autoStopTask == nil else { return }
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.autoStopTask = nil
            guard self.isRunning, !self.onDashWifi, !self.bikeConnected, !self.navigator.isNavigating else { return }
            self.stop(byUser: false, reason: "by auto connect (\(reason))")
        }
    }

    // MARK: State

    private func startLocation(background: Bool) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.allowsBackgroundLocationUpdates = background
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { locationManager.startUpdatingHeading() }
    }

    private func setState(_ newState: BroadcastState, _ text: String) {
        if newState != state { EventLog.record("STATE", "\(newState.rawValue): \(text)") }
        state = newState
        message = text
    }

    private func refreshScene() {
        let style = DashSettings.currentStyle()
        store.set(style: style)
        maps.set(style: style)
        let zoom = DashSettings.zoom
        store.set(zoom: zoom)
        store.set(threeD: DashSettings.threeD)
        store.set(mapOnRight: DashSettings.mapOnRight)
        maps.set(zoom: zoom)
        let vehicle = vehicleSource?() ?? DashScene.Vehicle()
        if vehicle != self.vehicle { self.vehicle = vehicle }
        store.set(vehicle: vehicle)
        let alert = RideAlerts.alert(for: vehicle, distanceAhead: navigator.distanceAhead)
        store.set(alert: alert)
        if let alert, isRunning { voice.alert(alert.spoken) }
        sceneTicks += 1
        if isRunning, sceneTicks % 180 == 0, let refreshVehicleData { Task { await refreshVehicleData() } }
        store.set(navigation: navigator.sceneNavigation())
        if !navigator.isNavigating { maps.set(mode: .overview) }
    }

    private func watchPhoneState() {
        let center = NotificationCenter.default
        let changes: [(Notification.Name, String)] = [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "Phone locked."),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "Phone unlocked."),
            (UIApplication.didEnterBackgroundNotification, "App went to the background."),
            (UIApplication.willEnterForegroundNotification, "App back in front."),
        ]
        for (name, line) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.log("\(line) Frames so far: \(self.dash?.framesPushed ?? 0).")
                    if name == UIApplication.didEnterBackgroundNotification { self.appActive = false }
                    if name == UIApplication.willEnterForegroundNotification { self.appActive = true }
                    self.updatePreview()
                }
            })
        }
    }

    private func handle(_ location: CLLocation) {
        lastLocation = location
        let speed = location.speed >= 0 ? Int((location.speed * 3.6).rounded()) : nil
        if speed != speedKmh { speedKmh = speed }
        guard isRunning else { return }
        store.set(location: location)
        trips.add(location)
        navigator.update(with: location)
        maps.set(mode: navigator.isNavigating ? .guidance : .overview)
        maps.update(for: location)
        voice.update(status: navigator.status, progress: navigator.progress, route: navigator.route,
                     speed: location.speed, stopsReached: navigator.stopsReached)
        let camera = cameras.update(location, progress: navigator.progress, guiding: navigator.status == .guiding)
        store.set(camera: camera.ahead)
        if let speech = camera.say { voice.announce(speech) }
        store.set(navigation: navigator.sceneNavigation())
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in self.handle(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0, newHeading.headingAccuracy < 45 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.store.set(compass: heading) }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus.rawValue
        Task { @MainActor in self.log("Location authorization now \(status).") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in self.log("Location error: \(text)") }
    }
}

/// Draws and encodes the dash screen on its own queue at a steady rate.
final class DashFrameLoop {
    static let frameRate = 20
    static let bitRate = 3_000_000
    /// A key frame at least this often, so a dash that missed one recovers quickly.
    private static let keyFrameEverySeconds = 2

    var onAccessUnit: ((Data) -> Void)?
    /// A copy of the frame, five times a second, while previewEnabled.
    var onPreview: ((CGImage) -> Void)?
    var previewEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return previewOn }
        set { lock.lock(); previewOn = newValue; lock.unlock() }
    }

    private let encoder: SoftwareVideoEncoder
    private let context: CGContext
    private let renderer: DashRenderer
    private let store: DashSceneStore
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "smartauto.dash.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var keyFrameRequested = true // guarded by `lock`
    private var previewOn = false // guarded by `lock`

    // Render queue only.
    private var motion = DashMotion()
    private var tickCount = 0
    private var thermal = ProcessInfo.ThermalState.nominal
    private var frameIndex = 0
    private var lastKeyFrame = 0
    private var failures = 0
    private var statFrames = 0
    private var statDrawNanos: UInt64 = 0
    private var statEncodeNanos: UInt64 = 0
    private var statBytes = 0
    private var statStart = DispatchTime.now().uptimeNanoseconds

    /// Call on the main thread: the renderer prepares its symbol images there.
    init?(size: CGSize, store: DashSceneStore, log: @escaping (String) -> Void) {
        guard let encoder = SoftwareVideoEncoder(width: Int(size.width), height: Int(size.height),
                                                 bitRate: Self.bitRate, frameRate: Self.frameRate),
              let context = encoder.makeContext()
        else { return nil }
        self.encoder = encoder
        self.context = context
        self.renderer = DashRenderer(size: size)
        self.store = store
        self.log = log
        log("Software H.264 encoder ready: \(Int(size.width))x\(Int(size.height)) \(Self.frameRate) fps " +
            "\(Self.bitRate / 1000) kbps, key frame every \(Self.keyFrameEverySeconds) s.")
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / Self.frameRate), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func requestKeyFrame() {
        lock.lock()
        keyFrameRequested = true
        lock.unlock()
    }

    private func tick() {
        // A phone in a mount in the sun gets hot (a common CarPlay and Android Auto complaint), and
        // iOS slows it down or stops the app. Hot: 10 fps; very hot: about 7.
        tickCount += 1
        if tickCount % Self.frameRate == 0 {
            let state = ProcessInfo.processInfo.thermalState
            if state != thermal {
                thermal = state
                log("Phone is \(Self.thermalName(state)): dash at \(Self.frameRate / framesDivisor) fps.")
            }
        }
        if tickCount % framesDivisor != 0 { return }

        lock.lock()
        var keyFrame = keyFrameRequested
        keyFrameRequested = false
        lock.unlock()
        if frameIndex - lastKeyFrame >= Self.frameRate * Self.keyFrameEverySeconds { keyFrame = true }

        let drawStart = DispatchTime.now().uptimeNanoseconds
        var scene = store.scene()
        (scene.position, scene.course) = motion.step(latest: scene.location, compass: scene.compass, now: scene.date)
        renderer.draw(scene, in: context)
        if frameIndex % 4 == 0, previewEnabled, let image = context.makeImage() {
            onPreview?(image)
        }
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        guard let accessUnit = encoder.encode(context, keyFrame: keyFrame) else {
            failures += 1
            if failures == 1 || failures % 100 == 0 { log("Encoding failed (\(failures) so far).") }
            requestKeyFrame()
            return
        }
        let done = DispatchTime.now().uptimeNanoseconds
        if keyFrame { lastKeyFrame = frameIndex }
        onAccessUnit?(accessUnit)
        frameIndex += 1

        statFrames += 1
        statDrawNanos += encodeStart - drawStart
        statEncodeNanos += done - encodeStart
        statBytes += accessUnit.count
        let elapsed = done - statStart
        if elapsed >= 10_000_000_000 {
            let frames = Double(statFrames)
            log(String(format: "Dash screen: %.1f fps, draw %.1f ms, encode %.1f ms, %.1f KB/frame, thermal %@.",
                       frames / (Double(elapsed) / 1e9), Double(statDrawNanos) / frames / 1e6,
                       Double(statEncodeNanos) / frames / 1e6, Double(statBytes) / frames / 1024,
                       Self.thermalName(ProcessInfo.processInfo.thermalState)))
            statFrames = 0
            statDrawNanos = 0
            statEncodeNanos = 0
            statBytes = 0
            statStart = done
        }
    }

    private var framesDivisor: Int {
        switch thermal {
        case .serious: return 2
        case .critical: return 3
        default: return 1
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
