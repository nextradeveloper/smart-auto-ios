import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Step 1 of Smart Auto's own dash screen: prove a picture this app draws reaches the 368G and
/// keeps going with the phone locked.
///
/// Screen share stops when the phone locks, because it records the screen. This draws its own
/// picture instead, encodes it on the CPU (SoftwareVideoEncoder: iOS takes the hardware encoder
/// away in the background) and stays alive on location updates, the way navigation apps do.
@MainActor
final class LockedDashTest: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message = ""
    @Published private(set) var framesSent = 0

    private let keepAlive = LocationKeepAlive()
    private var dash: DashSession?
    private var engine: TestScreenEngine?
    private var statusTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private func log(_ text: String) {
        EventLog.record("OWNDASH", text)
    }

    func start() {
        guard !isRunning else { return }
        let profile = DashProfile.byID(SharedStore.profileID)
        log("Own dash screen test starting. Profile \(profile.id), Wi-Fi \(DashLocator.wifiAddressDescription()).")
        guard let engine = TestScreenEngine(
            width: profile.fallbackWidth, height: profile.fallbackHeight,
            frameRate: TestScreenEngine.frameRate, bitRate: TestScreenEngine.bitRate,
            log: { EventLog.record("OWNDASH", $0) }
        ) else {
            log("The software H.264 encoder could not start.")
            message = "เริ่มตัวเข้ารหัสภาพไม่ได้"
            return
        }
        keepAlive.start()

        let dash = DashSession(profile: profile) { EventLog.record("DASH", $0) }
        dash.onEvent = { [weak self, weak engine] event in
            switch event {
            case let .state(_, text):
                Task { @MainActor in self?.message = text }
            case .streamStart, .linkUp, .needKeyFrame, .videoArea:
                engine?.requestKeyFrame()
            }
        }
        engine.onAccessUnit = { [weak dash] accessUnit in
            dash?.push(accessUnit)
        }
        self.engine = engine
        self.dash = dash
        watchPhoneState()
        engine.start()
        dash.start()
        isRunning = true
        message = "กำลังเชื่อมต่อจอรถ"
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.framesSent = self.dash?.framesPushed ?? 0
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        log("Own dash screen test stopped by the user after \(dash?.framesPushed ?? 0) frames.")
        statusTimer?.invalidate()
        statusTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        engine?.stop()
        dash?.stop()
        engine = nil
        dash = nil
        keepAlive.stop()
        isRunning = false
        message = ""
    }

    /// Lock and background changes go to the log and onto the test picture, so one field log
    /// shows whether frames kept flowing with the phone locked.
    private func watchPhoneState() {
        let center = NotificationCenter.default
        let changes: [(Notification.Name, String, String)] = [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "Phone locked.", "ล็อกจออยู่"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "Phone unlocked.", "ปลดล็อกแล้ว"),
            (UIApplication.didEnterBackgroundNotification, "App went to the background.", "แอปอยู่เบื้องหลัง"),
            (UIApplication.willEnterForegroundNotification, "App back in front.", "แอปเปิดอยู่"),
        ]
        for (name, line, label) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let engine = self.engine else { return }
                    self.log("\(line) Frames so far: \(self.dash?.framesPushed ?? 0).")
                    engine.setPhoneState(label)
                }
            })
        }
        engine?.setPhoneState(UIApplication.shared.applicationState == .active ? "แอปเปิดอยู่" : "แอปอยู่เบื้องหลัง")
    }
}

/// Draws and encodes the test picture on its own queue, at a steady rate.
final class TestScreenEngine {
    static let frameRate = 10
    static let bitRate = 1_500_000
    /// A key frame at least this often, so a dash that missed one recovers quickly.
    private static let keyFrameEverySeconds = 2

    var onAccessUnit: ((Data) -> Void)?

    private let encoder: SoftwareVideoEncoder
    private let context: CGContext
    private let frameRate: Int
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "smartauto.owndash.render", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var keyFrameRequested = true
    private var phoneState = ""

    // Render queue only.
    private var frameIndex = 0
    private var lastKeyFrame = 0
    private var failures = 0
    private var loggedFirstFrame = false
    private var statFrames = 0
    private var statDrawNanos: UInt64 = 0
    private var statEncodeNanos: UInt64 = 0
    private var statBytes = 0
    private var statStart = DispatchTime.now().uptimeNanoseconds

    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let clockFont = CTFontCreateUIFontForLanguage(.system, 150, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, 150, nil)
    private let titleFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 34, nil)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
    private let detailFont = CTFontCreateUIFontForLanguage(.system, 28, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, 28, nil)

    init?(width: Int, height: Int, frameRate: Int, bitRate: Int, log: @escaping (String) -> Void) {
        guard let encoder = SoftwareVideoEncoder(width: width, height: height, bitRate: bitRate, frameRate: frameRate),
              let context = encoder.makeContext()
        else { return nil }
        self.encoder = encoder
        self.context = context
        self.frameRate = frameRate
        self.log = log
        context.textMatrix = .identity
        log("Software H.264 encoder ready: \(width)x\(height) \(frameRate) fps \(bitRate / 1000) kbps, " +
            "key frame every \(Self.keyFrameEverySeconds) s.")
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / frameRate), leeway: .milliseconds(5))
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

    func setPhoneState(_ text: String) {
        lock.lock()
        phoneState = text
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let state = phoneState
        var keyFrame = keyFrameRequested
        keyFrameRequested = false
        lock.unlock()
        if frameIndex - lastKeyFrame >= frameRate * Self.keyFrameEverySeconds { keyFrame = true }

        let drawStart = DispatchTime.now().uptimeNanoseconds
        draw(phoneState: state)
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        guard let accessUnit = encoder.encode(context, keyFrame: keyFrame) else {
            failures += 1
            if failures == 1 || failures % 100 == 0 { log("Encoding failed (\(failures) so far).") }
            requestKeyFrame()
            return
        }
        let done = DispatchTime.now().uptimeNanoseconds
        if keyFrame { lastKeyFrame = frameIndex }
        if !loggedFirstFrame {
            loggedFirstFrame = true
            let headers = H264NAL.headers(inAnnexB: accessUnit).map { String(format: "%02x", $0) }.joined(separator: ",")
            let start = accessUnit.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
            log("First frame: \(accessUnit.count) bytes, NAL headers [\(headers)], starts \(start)")
        }
        onAccessUnit?(accessUnit)
        frameIndex += 1

        statFrames += 1
        statDrawNanos += encodeStart - drawStart
        statEncodeNanos += done - encodeStart
        statBytes += accessUnit.count
        let elapsed = done - statStart
        if elapsed >= 10_000_000_000 {
            let frames = Double(statFrames)
            let fps = frames / (Double(elapsed) / 1e9)
            log(String(format: "Own screen: %.1f fps, draw %.1f ms, encode %.1f ms, %.1f KB/frame, phone: %@.",
                       fps, Double(statDrawNanos) / frames / 1e6, Double(statEncodeNanos) / frames / 1e6,
                       Double(statBytes) / frames / 1024, state))
            statFrames = 0
            statDrawNanos = 0
            statEncodeNanos = 0
            statBytes = 0
            statStart = done
        }
    }

    // MARK: Drawing

    private func draw(phoneState: String) {
        let width = CGFloat(encoder.width)
        let height = CGFloat(encoder.height)
        context.setFillColor(CGColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let cyan = CGColor(red: 0.2, green: 0.85, blue: 1, alpha: 1)
        let grey = CGColor(red: 0.65, green: 0.7, blue: 0.75, alpha: 1)

        // Core Graphics counts y from the bottom.
        drawText("Smart Auto · ทดสอบจอของเราเอง", font: titleFont, color: cyan, centerX: width / 2, baseline: height - 70)
        drawText(clockFormatter.string(from: Date()), font: clockFont, color: white, centerX: width / 2, baseline: height / 2 - 40)
        drawText("เฟรม \(frameIndex) · โทรศัพท์: \(phoneState)", font: detailFont, color: grey, centerX: width / 2, baseline: 70)

        // A bar sweeping across: smooth movement shows the frame rate at a glance.
        let travel = width + 240
        let x = CGFloat(frameIndex * 16).truncatingRemainder(dividingBy: travel) - 240
        context.setFillColor(cyan)
        context.fill(CGRect(x: x, y: 24, width: 240, height: 14))
    }

    private func drawText(_ text: String, font: CTFont, color: CGColor, centerX: CGFloat, baseline: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: centerX - lineWidth / 2, y: baseline)
        CTLineDraw(line, context)
    }
}
