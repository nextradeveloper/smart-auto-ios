import AVFoundation
import Foundation

/// Spoken turn-by-turn in Thai, through whatever the phone plays to: on a bike, usually a helmet
/// headset over Bluetooth. CarPlay and Android Auto speak each turn ahead of time and again at it,
/// and lower the music while they do; riders need that more than drivers, since they can hardly
/// look at a screen. Works behind the lock screen (audio background mode).
@MainActor
final class DashVoice: NSObject, AVSpeechSynthesizerDelegate {
    private enum Stage { case early, prepare, now }

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "th-TH")
    private var step: Int?
    private var spoken: Set<Stage> = []
    private var lastStatus: DashNavigator.Status = .idle
    private var lastStopsReached = 0
    private var alerted: [String: Date] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func update(status: DashNavigator.Status, progress: DashRouteProgress?, route: DashRoute?, speed: Double,
                stopsReached: Int) {
        defer {
            lastStatus = status
            lastStopsReached = stopsReached
        }
        guard DashSettings.voice else {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
            return
        }
        if stopsReached > lastStopsReached, status == .guiding {
            say("ถึงจุดแวะแล้ว")
        }
        if status != lastStatus {
            switch status {
            case .guiding where lastStatus == .idle:
                say("เริ่มนำทาง")
            case .rerouting:
                step = nil
                say("กำลังหาเส้นทางใหม่")
            case .arrived:
                say("ถึงที่หมายแล้ว")
            case .idle:
                step = nil
            default:
                break
            }
        }
        guard status == .guiding, let progress, let route, let next = progress.nextStep, next < route.steps.count
        else { return }
        if next != step {
            step = next
            spoken = []
        }
        let instruction = route.steps[next].instruction
        guard !instruction.isEmpty else { return }
        let isLast = next == route.steps.count - 1
        let distance = progress.distanceToNextStep
        let stages = Self.stages(distance: distance, speed: speed)

        if stages.now {
            // At the turn itself; arriving is said when it happens.
            guard !spoken.contains(.now), !isLast else { return }
            spoken.formUnion([.early, .prepare, .now])
            say(instruction)
        } else if stages.prepare {
            guard !spoken.contains(.prepare) else { return }
            spoken.formUnion([.early, .prepare])
            say("อีก \(Self.spokenDistance(distance)) \(instruction)")
        } else if stages.early {
            guard !spoken.contains(.early) else { return }
            spoken.insert(.early)
            say("อีก \(Self.spokenDistance(distance)) \(instruction)")
        }
    }

    /// Which announcement is due `distance` metres before a turn at `speed` m/s: about a kilometre
    /// ahead, about 12 s ahead (at least 180 m), and at the turn (about 3 s, at least 35 m).
    nonisolated static func stages(distance: Double, speed: Double) -> (early: Bool, prepare: Bool, now: Bool) {
        let speed = max(speed, 0)
        let nowAt = max(35, speed * 3)
        let prepareAt = max(180, speed * 12)
        return (distance <= 1000 && distance > prepareAt + 200, distance <= prepareAt && distance > nowAt, distance <= nowAt)
    }

    /// "250 เมตร", "1.5 กิโลเมตร", "2 กิโลเมตร".
    nonisolated static func spokenDistance(_ meters: Double) -> String {
        if meters < 950 { return "\(max(50, Int((meters / 50).rounded()) * 50)) เมตร" }
        let kilometres = (meters / 100).rounded() / 10
        if kilometres == kilometres.rounded() { return "\(Int(kilometres)) กิโลเมตร" }
        return String(format: "%.1f กิโลเมตร", kilometres)
    }

    /// News about the route ("พบเส้นทางที่เร็วกว่า…"), after anything being said.
    func announce(_ text: String) {
        guard DashSettings.voice else { return }
        say(text, interrupt: false)
    }

    /// A warning (fuel, tyres), said once every half hour at most and after anything being said.
    func alert(_ text: String) {
        guard DashSettings.voice else { return }
        if let last = alerted[text], Date().timeIntervalSince(last) < 30 * 60 { return }
        alerted[text] = Date()
        say(text, interrupt: false)
    }

    private func say(_ text: String, interrupt: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            EventLog.record("VOICE", "Audio session failed: \(error.localizedDescription)")
        }
        if interrupt, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        EventLog.record("VOICE", text)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            // Music back to full volume.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
