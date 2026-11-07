import Api
import Foundation
import ReplayKit

/// The broadcast upload extension: iOS keeps it alive for as long as the screen broadcast runs,
/// whichever app is in front (iCarCast showing CarPlay), which is why the dash link lives here
/// and not in the app.
final class SampleHandler: RPBroadcastSampleHandler {
    private var pipeline: VideoPipeline?
    private var dash: DashSession?
    private var statusTimer: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private let stateQueue = DispatchQueue(label: "smartauto.state")
    private var state: BroadcastState = .searching
    private var message = ""
    private var streamWidth = 0
    private var streamHeight = 0

    private func log(_ message: String) {
        EventLog.record("EXT", message)
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // The extension is killed at about 50 MB; keep the Go heap well inside that.
        _ = ApiSetMemoryLimit(24 << 20)

        let profile = DashProfile.byID(SharedStore.profileID)
        let quality = SharedStore.quality
        let bitRate = Int(Double(profile.baseBitRate) * quality.multiplier)
        log("Broadcast started. Profile \(profile.id), quality \(quality.rawValue) (\(bitRate / 1000) kbps), " +
            "flip \(SharedStore.flipPicture), Wi-Fi \(DashLocator.wifiAddressDescription()).")

        let pipeline = VideoPipeline()
        let dash = DashSession(profile: profile, log: { EventLog.record("DASH", $0) })
        pipeline.log = { EventLog.record("VIDEO", $0) }
        pipeline.onAccessUnit = { [weak dash] accessUnit, _ in
            dash?.push(accessUnit)
        }
        dash.onEvent = { [weak self, weak pipeline] event in
            switch event {
            case let .state(newState, text):
                self?.setState(newState, text)
            case let .videoArea(width, height):
                pipeline?.resize(width: width, height: height)
                pipeline?.requestKeyFrame()
                self?.stateQueue.async {
                    self?.streamWidth = width
                    self?.streamHeight = height
                }
            case .streamStart, .linkUp, .needKeyFrame:
                pipeline?.requestKeyFrame()
            }
        }
        self.pipeline = pipeline
        self.dash = dash
        stateQueue.sync {
            streamWidth = profile.fallbackWidth
            streamHeight = profile.fallbackHeight
        }

        pipeline.start(
            width: profile.fallbackWidth,
            height: profile.fallbackHeight,
            frameRate: profile.frameRate,
            bitRate: bitRate,
            flip: SharedStore.flipPicture
        )
        dash.start()
        startStatusTimer()
        watchMemoryPressure()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        pipeline?.submit(sampleBuffer)
    }

    override func broadcastPaused() {
        log("Broadcast paused.")
    }

    override func broadcastResumed() {
        log("Broadcast resumed.")
        pipeline?.requestKeyFrame()
    }

    override func broadcastFinished() {
        log("Broadcast finished.")
        statusTimer?.cancel()
        statusTimer = nil
        memoryPressure?.cancel()
        memoryPressure = nil
        dash?.stop()
        pipeline?.stop()
        dash = nil
        pipeline = nil
        setState(.stopped, "")
        writeStatus()
    }

    // MARK: Status

    private func setState(_ newState: BroadcastState, _ text: String) {
        stateQueue.async {
            if self.state != newState {
                EventLog.record("STATE", "\(newState.rawValue): \(text)")
            }
            self.state = newState
            self.message = text
        }
    }

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.writeStatusLocked() }
        timer.resume()
        statusTimer = timer
    }

    private func writeStatus() {
        stateQueue.sync { writeStatusLocked() }
    }

    /// Runs on `stateQueue`.
    private func writeStatusLocked() {
        SharedStore.writeStatus(BroadcastStatus(
            state: state,
            message: message,
            framesSent: dash?.framesPushed ?? 0,
            fps: (dash?.isLinkUp ?? false) ? (pipeline?.measuredFps ?? 0) : 0,
            width: streamWidth,
            height: streamHeight,
            updatedAt: Date()
        ))
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: stateQueue)
        source.setEventHandler { [weak self] in
            EventLog.record("EXT", "Memory pressure: trimming.")
            ApiFreeMemory()
            self?.pipeline?.trimMemory()
        }
        source.resume()
        memoryPressure = source
    }
}
