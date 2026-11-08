import CoreLocation
import Foundation
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

    /// Bike state for the ride card; polled once a second while running.
    var vehicleSource: (@MainActor () -> DashScene.Vehicle)?

    private let store = DashSceneStore()
    private let maps = DashMapProvider()
    private let locationManager = CLLocationManager()
    private var dash: DashSession?
    private var loop: DashFrameLoop?
    private var statusTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        let store = store
        maps.onMap = { store.set(map: $0) }
    }

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    func start() {
        guard !isRunning else { return }
        let profile = DashProfile.byID(SharedStore.profileID)
        log("Dash screen starting. Profile \(profile.id), Wi-Fi \(DashLocator.wifiAddressDescription()).")
        let size = CGSize(width: profile.fallbackWidth, height: profile.fallbackHeight)
        guard let loop = DashFrameLoop(size: size, store: store, log: { EventLog.record("OWNDASH", $0) }) else {
            log("The software H.264 encoder could not start.")
            setState(.failed, "เริ่มตัวเข้ารหัสภาพไม่ได้")
            return
        }

        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()

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
        self.loop = loop
        self.dash = dash
        watchPhoneState()
        pollVehicle()
        loop.start()
        dash.start()
        isRunning = true
        setState(.connecting, "กำลังเชื่อมต่อจอรถ")
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollVehicle() }
        }
    }

    func stop() {
        guard isRunning else { return }
        log("Dash screen stopped by the user after \(dash?.framesPushed ?? 0) frames.")
        statusTimer?.invalidate()
        statusTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        loop?.stop()
        dash?.stop()
        loop = nil
        dash = nil
        maps.reset()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        isRunning = false
        setState(.stopped, "")
    }

    private func setState(_ newState: BroadcastState, _ text: String) {
        if newState != state { EventLog.record("STATE", "\(newState.rawValue): \(text)") }
        state = newState
        message = text
    }

    private func pollVehicle() {
        store.set(vehicle: vehicleSource?() ?? DashScene.Vehicle())
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
                }
            })
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            guard self.isRunning else { return }
            self.store.set(location: location)
            self.maps.update(for: location)
        }
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
    static let frameRate = 12
    static let bitRate = 1_800_000
    /// A key frame at least this often, so a dash that missed one recovers quickly.
    private static let keyFrameEverySeconds = 2

    var onAccessUnit: ((Data) -> Void)?

    private let encoder: SoftwareVideoEncoder
    private let context: CGContext
    private let renderer: DashRenderer
    private let store: DashSceneStore
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "smartauto.dash.render", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var keyFrameRequested = true // guarded by `lock`

    // Render queue only.
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
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / Self.frameRate), leeway: .milliseconds(5))
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
        lock.lock()
        var keyFrame = keyFrameRequested
        keyFrameRequested = false
        lock.unlock()
        if frameIndex - lastKeyFrame >= Self.frameRate * Self.keyFrameEverySeconds { keyFrame = true }

        let drawStart = DispatchTime.now().uptimeNanoseconds
        renderer.draw(store.scene(), in: context)
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
