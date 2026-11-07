import Api
import Foundation

/// One EasyConn link to the dash, kept up for as long as the broadcast runs.
///
/// Port of the Android app's RideDaemonTransport for the Zontes 368G only: wake probe on
/// 10930, EC init carrying the acknowledged probe package, then the Go library listens on
/// 10920-10922 for the dash to connect back and pulls our frames at its own pace.
///
/// A fresh Go MobileSession is made for every attempt: StopSession on a session that never
/// ran marks it stopped for good, so a session object is never reused after a failure.
final class DashSession {
    enum Event {
        case state(BroadcastState, String)
        case videoArea(width: Int, height: Int)
        case streamStart
        /// Passthrough only: the Go queue is waiting for an IDR the host must make its source send.
        case needKeyFrame
        /// The EasyConn session came up; the dash will ask for video next.
        case linkUp
    }

    /// How the frames reach the dash.
    struct Options {
        /// Relay a stream this app did not encode (CarPlay from iCarCast): see Go's PassthroughMode.
        var passthrough = false
        /// Announced to the dash as the stream size; 0x0 echoes the size the dash asks for.
        var captureWidth = 0
        var captureHeight = 0

        static let encoded = Options()
    }

    var onEvent: ((Event) -> Void)?

    private let profile: DashProfile
    private let options: Options
    private let log: (String) -> Void
    private let workQueue = DispatchQueue(label: "smartauto.dash.work")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var current: ApiMobileSession?
    private var currentEnded: DispatchSemaphore?
    private var generation = 0
    private var stopping = false
    private var linkUp = false
    private var pushedFrames = 0

    init(profile: DashProfile, options: Options = .encoded, log: @escaping (String) -> Void) {
        self.profile = profile
        self.options = options
        self.log = log
    }

    var framesPushed: Int {
        lock.lock(); defer { lock.unlock() }
        return pushedFrames
    }

    var isLinkUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return linkUp
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    func start() {
        workQueue.async { [weak self] in self?.connectLoop() }
    }

    func stop() {
        lock.lock()
        stopping = true
        let session = linkUp ? current : nil
        let ended = currentEnded
        linkUp = false
        lock.unlock()
        if let session {
            do {
                try session.stop()
            } catch {
                log("StopSession: \(error.localizedDescription)")
            }
        }
        ended?.signal()
    }

    /// Hands one Annex-B access unit to the dash's live queue. Dropped while the link is down.
    func push(_ accessUnit: Data) {
        lock.lock()
        guard linkUp, let session = current else {
            lock.unlock()
            return
        }
        pushedFrames += 1
        lock.unlock()
        session.pushFrame(accessUnit)
    }

    // MARK: Connect loop

    private func connectLoop() {
        var attempt = 0
        while !isStopping {
            attempt += 1
            emit(.state(attempt == 1 ? .searching : .reconnecting, "หาจอรถ (ครั้งที่ \(attempt))"))
            let located = DashLocator.locate(log: log, isCancelled: { [weak self] in self?.isStopping ?? true })
            switch located {
            case let .failure(failure):
                if case .cancelled = failure { return }
                log("Locate failed: \(failure)")
                emit(.state(.reconnecting, failure.description))
                pause(seconds: 3)
            case let .success(endpoint):
                runSession(to: endpoint)
                if !isStopping {
                    emit(.state(.reconnecting, "การเชื่อมต่อกับจอหลุด กำลังต่อใหม่"))
                    pause(seconds: 2)
                }
            }
        }
    }

    private func pause(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !isStopping {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func makeConfig() -> ApiMobileConfig? {
        // static signal, fps, startup, teardown, discovery timeout, discovery tries - as Android.
        guard let config = ApiNewMobileConfig(Data(), profile.frameRate, 25, 5, 10, 3) else { return nil }
        config.supportFunction = profile.supportFunction
        config.proactivePxcHeartbeatEnabled = profile.proactivePxcHeartbeat
        config.plainVideoFramingAllowed = profile.plainVideoFraming
        config.pageSwitchProbeEnabled = false
        config.jpegStillsEnabled = false
        config.clientPackage = profile.clientPackage
        config.phoneBrand = profile.phoneBrand
        config.phoneModel = profile.phoneModel
        config.clientVersionCode = profile.clientVersionCode
        config.clientVersionFingerprint = profile.clientVersionFingerprint
        config.phoneOsVersion = profile.phoneOsVersion
        config.clientInfoSupportFunction = profile.clientInfoSupportFunction
        config.timeZoneID = TimeZone.current.identifier
        config.timeZoneOffsetSeconds = TimeZone.current.secondsFromGMT()
        config.skipDashClockSync = false
        config.dashAsksForTime = false
        config.passthroughMode = options.passthrough
        config.captureWidth = options.captureWidth
        config.captureHeight = options.captureHeight
        return config
    }

    /// Opens one session and blocks until it ends (or the broadcast stops).
    private func runSession(to endpoint: DashEndpoint) {
        guard let config = makeConfig() else {
            log("Could not create the Go config")
            return
        }
        lock.lock()
        generation += 1
        let myGeneration = generation
        lock.unlock()

        let callback = SessionCallback(generation: myGeneration) { [weak self] generation, event in
            self?.handle(event, generation: generation)
        }
        var error: NSError?
        guard let session = ApiNewMobileSession(config, callback, &error) else {
            log("NewMobileSession failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        let ended = DispatchSemaphore(value: 0)
        lock.lock()
        current = session
        currentEnded = ended
        lock.unlock()

        log(
            "EC init to \(endpoint.host):\(endpoint.port) as probe package \(endpoint.probePackage); " +
                "client \(profile.clientPackage) v\(profile.clientVersionCode) (\(profile.id))"
        )
        emit(.state(.connecting, "เชื่อมต่อจอที่ \(endpoint.host)"))
        do {
            try session.setECHost(ApiNewStreamHost(endpoint.host, String(endpoint.port), endpoint.probePackage))
            // Blocks until the dash's first PXC heartbeat, or 25 s.
            try session.start()
        } catch {
            log("StartSession failed: \(error.localizedDescription)")
            emit(.state(.reconnecting, "จอไม่ตอบรับการเชื่อมต่อ: \(error.localizedDescription)"))
            // Releases the 10920-10922 listeners; this session object is discarded anyway.
            try? session.stop()
            clear(generation: myGeneration)
            return
        }

        lock.lock()
        let stillWanted = !stopping && generation == myGeneration
        if stillWanted { linkUp = true }
        lock.unlock()
        guard stillWanted else {
            try? session.stop()
            clear(generation: myGeneration)
            return
        }
        log("EasyConn session is up; waiting for the dash to request video.")
        emit(.state(.waitingForDash, "เชื่อมต่อจอแล้ว รอจอขอภาพ"))
        emit(.linkUp)

        ended.wait()
        clear(generation: myGeneration)
    }

    private func clear(generation ending: Int) {
        lock.lock()
        if generation == ending {
            linkUp = false
            current = nil
            currentEnded = nil
        }
        lock.unlock()
    }

    // MARK: Go callbacks

    private func handle(_ event: SessionCallback.Event, generation eventGeneration: Int) {
        lock.lock()
        let isCurrent = eventGeneration == generation
        let ended = currentEnded
        lock.unlock()
        guard isCurrent else { return }

        switch event {
        case let .error(message, fatal):
            log("Go \(fatal ? "fatal" : "warning"): \(message)")
        case .stopped:
            log("Go session stopped.")
            lock.lock()
            linkUp = false
            lock.unlock()
            ended?.signal()
        case let .event(source, command, payload):
            handleDashEvent(source: source, command: command, payload: payload)
        }
    }

    private func handleDashEvent(source: Int, command: Int, payload: Data) {
        switch (source, command) {
        case (3, 16):
            // CAPTURE_CONFIG: u16le width @0, u16le height @2. Go answers with the 16-aligned
            // size itself, so the stream has to be exactly that.
            guard payload.count >= 4 else { return }
            let width = Int(payload[payload.startIndex]) | Int(payload[payload.startIndex + 1]) << 8
            let height = Int(payload[payload.startIndex + 2]) | Int(payload[payload.startIndex + 3]) << 8
            if options.captureWidth > 0, options.captureHeight > 0 {
                log("Dash video area \(width)x\(height); announced the relayed stream's " +
                    "\(options.captureWidth)x\(options.captureHeight) instead.")
                return
            }
            let alignedWidth = max(16, width & ~15)
            let alignedHeight = max(16, height & ~15)
            log("Dash video area \(width)x\(height) -> stream \(alignedWidth)x\(alignedHeight)")
            emit(.videoArea(width: alignedWidth, height: alignedHeight))
        case (3, 112):
            log("Dash STREAM_START: sending an IDR.")
            emit(.streamStart)
            emit(.state(.streaming, "กำลังส่งภาพขึ้นจอ"))
        case (4, 4):
            // Go's EventNeedIDR: passthrough queue is waiting for an IDR.
            emit(.needKeyFrame)
        case (2, _):
            let text = String(decoding: payload.prefix(400), as: UTF8.self)
            log("PXC 0x\(String(command, radix: 16, uppercase: true)): \(text)")
        case (4, 2):
            // Video pulls: [phase, u64 BE]. Phase 1 = the dash pulled its first frame.
            if let phase = payload.first {
                let names = ["socket open", "first pull", "pulls", "closed"]
                let name = Int(phase) < names.count ? names[Int(phase)] : "phase \(phase)"
                var count: UInt64 = 0
                for byte in payload.dropFirst().prefix(8) { count = count << 8 | UInt64(byte) }
                if phase != 2 || count % 300 == 0 { log("Video \(name): \(count)") }
            }
        default:
            log("Event source=\(source) cmd=\(command) bytes=\(payload.count)")
        }
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}

/// Bridges the Go callback interface; tags every call with the session it belongs to so a
/// late callback from an abandoned session cannot touch the current one.
final class SessionCallback: NSObject, ApiMobileCallbackProtocol {
    enum Event {
        case error(String, Bool)
        case stopped
        case event(source: Int, command: Int, payload: Data)
    }

    private let generation: Int
    private let deliver: (Int, Event) -> Void
    private let queue = DispatchQueue(label: "smartauto.dash.callbacks")

    init(generation: Int, deliver: @escaping (Int, Event) -> Void) {
        self.generation = generation
        self.deliver = deliver
    }

    func onError(_ msg: String?, fatal: Bool) {
        let message = msg ?? ""
        queue.async { self.deliver(self.generation, .error(message, fatal)) }
    }

    func onEvent(_ time: Int64, source: Int, command: Int, payload: Data?) {
        let bytes = payload ?? Data()
        queue.async { self.deliver(self.generation, .event(source: source, command: command, payload: bytes)) }
    }

    func onStopped() {
        queue.async { self.deliver(self.generation, .stopped) }
    }
}
