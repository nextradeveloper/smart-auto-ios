import CoreLocation
import Foundation
import UIKit

/// Where the phone was when the vehicle was last parked. Thai vehicles have no 4G module, so
/// the phone remembers the spot instead of the vehicle reporting it.
struct ParkedSpot: Codable, Equatable {
    enum Source: String, Codable {
        case lock, walkAway, manual

        var title: String {
            switch self {
            case .lock: return "บันทึกตอนล็อกรถ"
            case .walkAway: return "บันทึกตอนเดินออกจากรถ"
            case .manual: return "บันทึกเอง"
            }
        }
    }

    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let date: Date
    let source: Source

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func distance(to other: ParkedSpot) -> CLLocationDistance { location.distance(from: other.location) }

    /// When Bluetooth drops, the phone is already 20–50 m away. A spot saved at Lock earlier in
    /// the same connection wins while it is still near, since the phone was beside the vehicle;
    /// if it is far, the vehicle was ridden after that lock.
    static func choose(lock: ParkedSpot?, walkAway: ParkedSpot) -> ParkedSpot {
        guard let lock, lock.date <= walkAway.date, lock.distance(to: walkAway) <= 80 else { return walkAway }
        return lock
    }
}

extension ParkedSpot {
    init(location: CLLocation, source: Source) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            date: location.timestamp,
            source: source
        )
    }
}

/// The last parked spot, per PKE code.
enum ParkedSpotStore {
    private static func key(_ pke: String) -> String { "parkedSpot.\(pke)" }

    static func load(pke: String) -> ParkedSpot? {
        guard let data = UserDefaults.standard.data(forKey: key(pke)) else { return nil }
        return try? JSONDecoder().decode(ParkedSpot.self, from: data)
    }

    static func save(_ spot: ParkedSpot, pke: String) {
        guard let data = try? JSONEncoder().encode(spot) else { return }
        UserDefaults.standard.set(data, forKey: key(pke))
    }
}

/// Saves the parked spot from Bluetooth events: at Lock (phone beside the vehicle) and when
/// the connection drops as the rider walks away, also while the app is in the background.
@MainActor
final class ParkingSpotTracker: NSObject, ObservableObject {
    @Published private(set) var spot: ParkedSpot?
    /// Only while the find screen is open.
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var pke = ""
    private var lockSpot: ParkedSpot?
    private var pending: [(source: ParkedSpot.Source, pke: String)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isLive = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // The app already declares the location background mode; this lets a fix finish
        // after Bluetooth wakes the app in the background.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        authorization = manager.authorizationStatus
    }

    func configure(pke: String) {
        guard pke != self.pke else { return }
        self.pke = pke
        lockSpot = nil
        spot = pke.isEmpty ? nil : ParkedSpotStore.load(pke: pke)
    }

    func handle(_ event: VehicleBluetoothMonitor.Event) {
        switch event {
        case .connected:
            lockSpot = nil
            requestPermission()
        case .locked:
            capture(.lock)
        case .unlocked:
            lockSpot = nil
        case .disconnected:
            capture(.walkAway)
        }
    }

    func saveCurrentLocation() {
        capture(.manual)
    }

    /// iOS asks "While Using" first and offers "Always" once the app uses location in the
    /// background; later calls do nothing.
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func startLive() {
        guard !isLive else { return }
        isLive = true
        requestPermission()
        manager.startUpdatingLocation()
    }

    func stopLive() {
        guard isLive else { return }
        isLive = false
        manager.stopUpdatingLocation()
        currentLocation = nil
    }

    private func capture(_ source: ParkedSpot.Source) {
        guard !pke.isEmpty else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            EventLog.record("PARK", "No location permission; \(source.rawValue) spot not saved.")
            return
        }
        if let recent = manager.location, recent.horizontalAccuracy >= 0, recent.horizontalAccuracy <= 50,
           -recent.timestamp.timeIntervalSinceNow < 10 {
            store(ParkedSpot(location: recent, source: source), pke: pke)
            return
        }
        pending.append((source, pke))
        beginBackgroundTask()
        if !isLive { manager.requestLocation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            EventLog.record("PARK", "No location fix in time; spot not saved.")
            self.pending.removeAll()
            self.endBackgroundTask()
        }
    }

    private func store(_ candidate: ParkedSpot, pke: String) {
        let chosen: ParkedSpot
        switch candidate.source {
        case .lock:
            lockSpot = candidate
            chosen = candidate
        case .walkAway:
            chosen = ParkedSpot.choose(lock: lockSpot, walkAway: candidate)
            lockSpot = nil
        case .manual:
            chosen = candidate
        }
        ParkedSpotStore.save(chosen, pke: pke)
        if pke == self.pke { spot = chosen }
        EventLog.record("PARK", "Saved parking spot (\(chosen.source.rawValue), ±\(Int(chosen.horizontalAccuracy)) m).")
    }

    private func received(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        if isLive { currentLocation = location }
        guard !pending.isEmpty else { return }
        let requests = pending
        pending.removeAll()
        for request in requests {
            store(ParkedSpot(location: location, source: request.source), pke: request.pke)
        }
        endBackgroundTask()
    }

    private func failed(_ message: String) {
        guard !pending.isEmpty else { return }
        EventLog.record("PARK", "Location failed: \(message)")
        pending.removeAll()
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ParkingSpot") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension ParkingSpotTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in self?.received(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.failed(message) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.authorization = status }
    }
}
