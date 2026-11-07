import CoreLocation
import Foundation
import UIKit

/// "CarPlay direct": relays the CarPlay stream iCarCast serves on this iPhone to the dash, with
/// no screen recording.
///
/// Why it is built this way (measured 2026-11-07 on the user's iPhone):
/// - iCarCast stops serving within ~20 s of going to the background and at once when the phone
///   locks, so iCarCast stays in front and this app runs behind it.
/// - iOS takes the hardware video encoder/decoder away from background apps, so this app cannot
///   re-encode; it hands CarPlay's own H.264 to the dash (Go PassthroughMode) and announces the
///   stream's real size (1920x720 recommended in iCarCast) instead of the dash's 1280x528.
/// - Location updates are what keep a background app running; the blue indicator shows it.
@MainActor
final class CarPlayDirect: ObservableObject {
    @Published private(set) var state: BroadcastState = .idle
    @Published private(set) var message = ""
    @Published private(set) var framesSent = 0
    @Published private(set) var streamSize = ""
    @Published private(set) var carPlayConnected = false

    var isRunning: Bool {
        switch state {
        case .idle, .stopped, .failed: return false
        default: return true
        }
    }

    private let keepAlive = LocationKeepAlive()
    private var stream: ICarCastStream?
    private var dash: DashSession?
    private var statusTimer: Timer?
    private var attempt = 0

    private func log(_ text: String) {
        EventLog.record("DIRECT", text)
    }

    func start() {
        guard !isRunning else { return }
        let profile = DashProfile.byID(SharedStore.profileID)
        log("CarPlay direct starting. Profile \(profile.id), Wi-Fi \(DashLocator.wifiAddressDescription()).")
        keepAlive.start()
        let stream = ICarCastStream(host: "127.0.0.1", httpsPort: SharedStore.iCarCastPort) { EventLog.record("ICARCAST", $0) }
        self.stream = stream
        attempt = 0
        setState(.searching, "รอ iCarCast (เปิด iCarCast › This iPhone ไว้)")
        fetchInfo(profile: profile)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCounters() }
        }
    }

    func stop() {
        log("CarPlay direct stopped by the user.")
        statusTimer?.invalidate()
        statusTimer = nil
        stream?.stop()
        dash?.stop()
        stream = nil
        dash = nil
        keepAlive.stop()
        carPlayConnected = false
        setState(.stopped, "")
    }

    /// Learns the stream size before the dash session starts, because the size goes into the
    /// capture reply the dash asks for right after connecting.
    private func fetchInfo(profile: DashProfile) {
        guard let stream else { return }
        attempt += 1
        // Asking with 1280x528 tells iCarCast what the car's screen is; this build answers with
        // its own setting, which is what gets announced.
        stream.fetchInfo(width: 1280, height: 528) { [weak self] result in
            Task { @MainActor in
                guard let self, self.stream === stream else { return }
                switch result {
                case let .failure(failure):
                    if self.attempt == 1 || self.attempt % 10 == 0 {
                        self.log("iCarCast not ready (attempt \(self.attempt)): \(failure)")
                    }
                    self.setState(.searching, "รอ iCarCast: \(failure.description)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.stream === stream else { return }
                        self.fetchInfo(profile: profile)
                    }
                case let .success(info):
                    self.begin(with: info, stream: stream, profile: profile)
                }
            }
        }
    }

    private func begin(with info: ICarCastStream.Info, stream: ICarCastStream, profile: DashProfile) {
        log("iCarCast stream: \(info.width)x\(info.height), WebSocket port \(info.port), build \(info.build).")
        streamSize = "\(info.width)×\(info.height)"
        if info.width * 100 / max(info.height, 1) < 200 {
            log("Warning: \(info.width)x\(info.height) is far from the dash's shape; set iCarCast's resolution to 1920x720.")
        }

        let options = DashSession.Options(passthrough: true, captureWidth: info.width, captureHeight: info.height)
        let dash = DashSession(profile: profile, options: options) { EventLog.record("DASH", $0) }
        self.dash = dash
        dash.onEvent = { [weak self, weak stream] event in
            switch event {
            case let .state(newState, text):
                Task { @MainActor in self?.setState(newState, text) }
            case .linkUp:
                stream?.requestKeyFrame(reason: "dash link up")
            case .streamStart:
                stream?.requestKeyFrame(reason: "dash STREAM_START")
            case .needKeyFrame:
                stream?.requestKeyFrame(reason: "dash queue waits for an IDR")
            case .videoArea:
                break
            }
        }
        stream.onAccessUnit = { [weak dash] accessUnit, _ in
            dash?.push(accessUnit)
        }
        stream.onConnection = { [weak self] connected in
            Task { @MainActor in self?.carPlayConnected = connected }
        }
        let night = UITraitCollection.current.userInterfaceStyle == .dark
        stream.start(socketPort: info.port, night: night)
        dash.start()
    }

    private func refreshCounters() {
        framesSent = dash?.framesPushed ?? 0
    }

    private func setState(_ newState: BroadcastState, _ text: String) {
        if newState != state { EventLog.record("STATE", "\(newState.rawValue): \(text)") }
        state = newState
        message = text
    }
}

/// Keeps the app running behind iCarCast: standard location updates are the background mode a
/// motorcycle app may hold for as long as it is navigating. Accuracy is kept coarse; the point
/// is staying alive, not tracking.
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        EventLog.record("DIRECT", "Location keep-alive on (authorization \(manager.authorizationStatus.rawValue)).")
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        EventLog.record("DIRECT", "Location authorization now \(manager.authorizationStatus.rawValue).")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        EventLog.record("DIRECT", "Location error: \(error.localizedDescription)")
    }
}
