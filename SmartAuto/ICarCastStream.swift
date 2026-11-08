import Foundation

/// The CarPlay picture iCarCast serves to a "car browser" (its Browser screen mode), read the way
/// iCarCast's own page reads it (main.js / video_decoder.js, 2026-11-07):
///
/// - `GET https://<host>:8081/getsocketport?w=..&h=..&webcodec=true` answers JSON with the
///   WebSocket `port` and the stream size (`video_width`/`video_height`).
/// - `wss://<host>:<port>`: send `{"action":"START"}` and `{"action":"NIGHT","value":bool}`, then
///   `{"action":"PING"}` every second. Binary messages are Annex-B H.264 (4-byte start codes):
///   SPS/PPS, IDR, P-frames; a lone NAL of type 31 is the pong.
///
/// Measured on the user's iPhone: High profile 4.2, up to 60 fps, frames only when the picture
/// changes, and an IDR only at the start of a connection - so a fresh IDR is had by reconnecting.
/// The server sends a certificate for v.tarplay.com; this client accepts it for its one host.
final class ICarCastStream: NSObject, URLSessionDelegate {
    struct Info {
        let port: Int
        let width: Int
        let height: Int
        let build: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case badReply(String)

        var description: String {
            switch self {
            case let .unreachable(reason): return "ติดต่อ iCarCast ไม่ได้ (\(reason))"
            case let .badReply(reason): return "iCarCast ตอบไม่ถูกรูปแบบ (\(reason))"
            }
        }
    }

    /// One Annex-B access unit, SPS and PPS in front of every IDR, and whether it is an IDR.
    var onAccessUnit: ((Data, Bool) -> Void)?
    /// Connected (true) or lost (false).
    var onConnection: ((Bool) -> Void)?

    private let host: String
    private let httpsPort: Int
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "smartauto.icarcast")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    // Owned by `queue`.
    private var socketPort = 0
    private var night = false
    private var running = false
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var heartbeat: DispatchSourceTimer?
    private var lastMessageAt = Date.distantPast
    private var lastKeyFrameRequest = Date.distantPast
    private var sps: Data?
    private var pps: Data?
    private var connected = false

    init(host: String, httpsPort: Int, log: @escaping (String) -> Void) {
        self.host = host
        self.httpsPort = httpsPort
        self.log = log
    }

    // MARK: Socket port

    func fetchInfo(width: Int, height: Int, completion: @escaping (Result<Info, Failure>) -> Void) {
        guard let url = URL(string: "https://\(host):\(httpsPort)/getsocketport?w=\(width)&h=\(height)&webcodec=true") else {
            completion(.failure(.badReply("url")))
            return
        }
        session.dataTask(with: url) { data, _, error in
            if let error {
                completion(.failure(.unreachable(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.badReply("not JSON")))
                return
            }
            if json["wrongresolution"] != nil {
                completion(.failure(.badReply("iCarCast is restarting with a new resolution")))
                return
            }
            func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
            guard let port = int("port") else {
                completion(.failure(.badReply("no port")))
                return
            }
            var width = int("video_width") ?? int("width") ?? 0
            var height = int("video_height") ?? int("height") ?? 0
            if width == 0 || height == 0 {
                switch int("resolution") {
                case 2: width = 1920; height = 1080
                case 1: width = 1280; height = 720
                default: break
                }
            }
            completion(.success(Info(port: port, width: width, height: height, build: int("buildversion") ?? 0)))
        }.resume()
    }

    // MARK: Stream

    func start(socketPort: Int, night: Bool) {
        queue.async {
            self.socketPort = socketPort
            self.night = night
            self.running = true
            self.connect()
            self.startHeartbeat()
        }
    }

    func stop() {
        queue.sync {
            running = false
            heartbeat?.cancel()
            heartbeat = nil
            generation += 1
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            setConnected(false)
        }
    }

    /// iCarCast sends an IDR only when a connection starts, so ask for one by reconnecting.
    func requestKeyFrame(reason: String) {
        queue.async {
            guard self.running else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastKeyFrameRequest) >= 1.5 else { return }
            self.lastKeyFrameRequest = now
            self.log("Reconnecting to iCarCast for a fresh IDR (\(reason)).")
            self.connect()
        }
    }

    /// Runs on `queue`.
    private func connect() {
        generation += 1
        let myGeneration = generation
        task?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "wss://\(host):\(socketPort)") else { return }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 8 * 1024 * 1024
        task = socket
        lastMessageAt = Date()
        socket.resume()
        send(["action": "START"], on: socket)
        send(["action": "NIGHT", "value": night], on: socket)
        receive(on: socket, generation: myGeneration)
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive(on socket: URLSessionWebSocketTask, generation myGeneration: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.running, myGeneration == self.generation else { return }
                switch result {
                case let .failure(error):
                    self.log("iCarCast stream closed: \(error.localizedDescription)")
                    self.setConnected(false)
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        if self.running, myGeneration == self.generation { self.connect() }
                    }
                case let .success(message):
                    self.lastMessageAt = Date()
                    if case let .data(data) = message {
                        self.handle(data)
                    }
                    self.receive(on: socket, generation: myGeneration)
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, let socket = self.task else { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 6 {
                // Pongs come every second while the server is alive; silence means it is gone
                // (iCarCast suspended, or the socket died without a close).
                self.log("No answer from iCarCast for 6 s; reconnecting.")
                self.setConnected(false)
                self.connect()
                return
            }
            self.send(["action": "PING"], on: socket)
        }
        timer.resume()
        heartbeat = timer
    }

    private func setConnected(_ value: Bool) {
        guard value != connected else { return }
        connected = value
        onConnection?(value)
    }

    // MARK: H.264

    /// Runs on `queue`.
    private func handle(_ message: Data) {
        let bytes = [UInt8](message)
        let nals = Self.nalUnits(in: bytes)
        guard !nals.isEmpty else { return }
        if nals.count == 1, nals[0].type == 31 { return } // pong

        if !connected {
            setConnected(true)
        }
        var hasIDR = false
        var hasSlice = false
        var hasSPS = false
        for nal in nals {
            switch nal.type {
            case 7:
                sps = Data(bytes[nal.range])
                hasSPS = true
            case 8:
                pps = Data(bytes[nal.range])
            case 5:
                hasIDR = true
            case 1:
                hasSlice = true
            default:
                break
            }
        }
        guard hasIDR || hasSlice else { return } // parameter sets only: cached above

        // Same NAL headers as screen share, which the 368G paints (Shared/H264NAL.swift); SEI and
        // AUDs are dropped there too.
        var accessUnit = Data()
        if hasIDR, !hasSPS, let sps, let pps {
            H264NAL.appendAnnexB(sps, to: &accessUnit)
            H264NAL.appendAnnexB(pps, to: &accessUnit)
        }
        for nal in nals where nal.type != 31 {
            H264NAL.appendAnnexB(Data(bytes[nal.range]), to: &accessUnit)
        }
        onAccessUnit?(accessUnit, hasIDR)
    }

    struct NAL {
        let type: UInt8
        /// Payload range in the message bytes, start code excluded.
        let range: Range<Int>
    }

    /// Splits on 3- or 4-byte start codes.
    static func nalUnits(in bytes: [UInt8]) -> [NAL] {
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        var nals: [NAL] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].codeStart : bytes.count
            guard start.payloadStart < end else { continue }
            nals.append(NAL(type: bytes[start.payloadStart] & 0x1F, range: start.payloadStart..<end))
        }
        return nals
    }

    // MARK: URLSessionDelegate

    /// iCarCast's certificate is for v.tarplay.com; trust it for the iCarCast host only.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
