import Foundation
import Network

/// The bike's camera unit (front and rear), on the bike's Wi-Fi at 192.168.3.1:7686.
///
/// The official ZONTES app (1.12, DVRActivity and its fragments) talks to it with JSON POSTs to the
/// root URL: VIDEO.DATE / VIDEO.TIME / VIDEO.INFO.LIST per camera ("front", "rear"),
/// PICTURE.INFO.LIST, LOG.FILE.LIST. It has no live view; `probeLiveView` looks for one.
struct DashcamClient {
    static let host = "192.168.3.1"
    static let base = URL(string: "http://192.168.3.1:7686")!

    enum Camera: String, CaseIterable, Identifiable {
        case front, rear
        var id: String { rawValue }
        var title: String { self == .front ? "หน้า" : "หลัง" }
    }

    struct Video: Identifiable, Hashable {
        let title: String
        let name: String
        let playURL: URL
        let thumbURL: URL?
        var id: String { playURL.absoluteString }
    }

    struct Picture: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    // MARK: Recordings

    func dates(_ camera: Camera) async throws -> [String] {
        let json = try await Self.call(["METHOD": "VIDEO.DATE", "previewType": camera.rawValue])
        return json["dateList"] as? [String] ?? []
    }

    func times(_ camera: Camera, date: String) async throws -> [String] {
        let json = try await Self.call(["METHOD": "VIDEO.TIME", "date": date, "previewType": camera.rawValue])
        return json["timeBeanList"] as? [String] ?? []
    }

    func videos(_ camera: Camera, date: String, time: String) async throws -> [Video] {
        let json = try await Self.call(["METHOD": "VIDEO.INFO.LIST", "date": date, "time": time, "index": 0,
                                        "num": 120, "previewType": camera.rawValue, "sort": "des"])
        return Self.objects(json["videoBeanList"]).compactMap { item in
            guard let play = Self.url(item["playUrl"]) else { return nil }
            return Video(title: item["title"] as? String ?? "", name: item["name"] as? String ?? "",
                         playURL: play, thumbURL: Self.url(item["thumbUrl"]))
        }
    }

    func pictures() async throws -> [Picture] {
        let json = try await Self.call(["METHOD": "PICTURE.INFO.LIST", "index": 0, "num": 100,
                                        "previewType": "all", "sort": "des"])
        return Self.objects(json["pictureBeanList"]).compactMap { Self.url($0["pictureUrl"]).map(Picture.init) }
    }

    /// Downloads a recording or photo to a temporary file named like the original.
    func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await Self.session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ZontesError.message("ดาวน์โหลดไม่สำเร็จ") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    // MARK: Wire

    static func call(_ body: [String: Any]) async throws -> [String: Any] {
        let raw = try await post(body)
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw ZontesError.message("กล้องตอบกลับไม่ถูกต้อง")
        }
        return json
    }

    static func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ZontesError.message("กล้องไม่ตอบ") }
            return data
        } catch let error as ZontesError {
            throw error
        } catch {
            throw ZontesError.message("ติดต่อกล้องไม่ได้ ต่อ Wi-Fi ของรถก่อน")
        }
    }

    /// The camera returns lists either as JSON objects or as JSON strings of objects.
    private static func objects(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let object = item as? [String: Any] { return object }
            if let text = item as? String, let data = text.data(using: .utf8) {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            return nil
        }
    }

    /// The camera writes "192.168.3.1:7686/..." without a scheme, or a path.
    private static func url(_ value: Any?) -> URL? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if text.hasPrefix("/") { text = base.absoluteString + text }
        if !text.contains("://") { text = "http://" + text }
        return URL(string: text.replacingOccurrences(of: " ", with: "%20"))
    }
}

// MARK: Live view probe

extension DashcamClient {
    /// Looks for a live picture the official app never uses: open ports, RTSP paths, HTTP paths and
    /// JSON methods a camera unit like this commonly has. Everything goes to the log (tag CAM);
    /// returns a one-line summary.
    func probeLiveView(progress: @escaping @MainActor (String) -> Void) async -> String {
        func log(_ text: String) { EventLog.record("CAM", text) }
        log("Live view probe started.")
        var found: [String] = []

        await progress("ตรวจพอร์ต")
        let ports: [UInt16] = [554, 8554, 80, 8080, 7686, 8081, 8000, 8888, 1935, 5000, 6000, 9000, 10080]
        var open: [UInt16] = []
        for port in ports {
            if await Self.tcpOpen(port) { open.append(port) }
        }
        log("Open ports: \(open.map(String.init).joined(separator: ", ")).")

        await progress("ตรวจ RTSP")
        let rtspPaths = ["", "live", "stream", "front", "rear", "ch0", "ch1", "main", "sub", "av0_0", "av0_1",
                         "livestream/12", "h264", "video", "cam", "preview", "0", "1", "11", "12"]
        for port in open where [554, 8554, 1935, 10080, 8000].contains(port) {
            for path in rtspPaths {
                let url = "rtsp://\(Self.host):\(port)/\(path)"
                let reply = await Self.rtspDescribe(url, port: port)
                log("RTSP \(url): \(reply)")
                if reply.contains("200") { found.append(url) }
            }
        }

        await progress("ตรวจ HTTP")
        let httpPaths = ["/", "/live", "/stream", "/video", "/mjpeg", "/preview", "/snapshot.jpg", "/snapshot",
                         "/live.flv", "/live.m3u8", "/front", "/rear", "/cgi-bin/hi3510/snap.cgi", "/?action=stream"]
        for port in open where [80, 8080, 7686, 8081, 8000, 8888, 9000].contains(port) {
            for path in httpPaths {
                guard let url = URL(string: "http://\(Self.host):\(port)\(path)") else { continue }
                let reply = await Self.httpHead(url)
                log("HTTP GET \(url.absoluteString): \(reply)")
                if reply.contains("200"), reply.contains("video") || reply.contains("image") || reply.contains("mpegurl")
                    || reply.contains("multipart") || reply.contains("flv") {
                    found.append(url.absoluteString)
                }
            }
        }

        await progress("ตรวจคำสั่งกล้อง")
        let methods = ["DEVICE.INFO", "DEV.INFO", "SYSTEM.INFO", "SYS.INFO", "VERSION", "CAMERA.INFO", "SETTING.INFO",
                       "SETTING.GET", "STATUS", "STATUS.INFO", "SD.INFO", "STORAGE.INFO", "LIVE.START", "LIVE.URL",
                       "LIVE.INFO", "PREVIEW.START", "PREVIEW.INFO", "PREVIEW.URL", "RTSP.URL", "RTSP.INFO",
                       "STREAM.INFO", "STREAM.START", "STREAM.URL", "REALTIME.START", "VIDEO.LIVE", "VIDEO.PREVIEW",
                       "VIDEO.STREAM", "MEDIA.INFO", "CAPABILITY", "WIFI.INFO", "RECORD.STATUS", "PICTURE.TAKE",
                       "SNAPSHOT"]
        for method in methods {
            for camera in [nil, "front"] {
                var body: [String: Any] = ["METHOD": method]
                if let camera { body["previewType"] = camera }
                let reply: String
                do {
                    reply = String(decoding: try await Self.post(body).prefix(300), as: UTF8.self)
                } catch {
                    reply = "error: \(error.localizedDescription)"
                }
                log("METHOD \(method)\(camera.map { " (\($0))" } ?? ""): \(reply)")
                let lower = reply.lowercased()
                if lower.contains("rtsp://") || lower.contains(".m3u8") || (lower.contains("live") && lower.contains("http")) {
                    found.append("METHOD \(method)")
                }
            }
        }

        // What the known calls answer, so the log shows the format and any stream URL inside.
        for body: [String: Any] in [["METHOD": "VIDEO.DATE", "previewType": "front"],
                                    ["METHOD": "VIDEO.DATE", "previewType": "rear"],
                                    ["METHOD": "PICTURE.INFO.LIST", "index": 0, "num": 2, "previewType": "all", "sort": "des"]] {
            let reply = (try? await Self.post(body)).map { String(decoding: $0.prefix(400), as: UTF8.self) } ?? "error"
            log("Known \(body["METHOD"] ?? "") \(body["previewType"] ?? ""): \(reply)")
        }

        let summary = found.isEmpty
            ? "ไม่พบภาพสด (พอร์ตที่เปิด: \(open.isEmpty ? "ไม่มี" : open.map(String.init).joined(separator: ", ")))"
            : "พบ: \(found.prefix(3).joined(separator: ", "))"
        log("Live view probe done. \(found.isEmpty ? "Nothing found." : "Found: \(found.joined(separator: " | "))")")
        return summary
    }

    private static func tcpOpen(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .waiting:
                    once.run { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                once.run { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    /// Sends RTSP DESCRIBE and returns the status line (and SDP media lines when there are any).
    private static func rtspDescribe(_ url: String, port: UInt16) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: (String) -> Void = { text in
                once.run { continuation.resume(returning: text) }
                connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "DESCRIBE \(url) RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\nUser-Agent: SmartAuto\r\n\r\n"
                    connection.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        let lines = text.components(separatedBy: "\r\n")
                        let useful = lines.prefix(1) + lines.filter { $0.hasPrefix("m=") || $0.hasPrefix("a=rtpmap") }
                        finish(useful.joined(separator: " | ").isEmpty ? "no reply" : useful.joined(separator: " | "))
                    }
                case .failed(let error):
                    finish("failed: \(error)")
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("timeout") }
        }
    }

    /// Status code and content type of a GET, reading only the start of the body.
    private static func httpHead(_ url: URL) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            var first = Data()
            for try await byte in bytes {
                first.append(byte)
                if first.count >= 64 { break }
            }
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
            let preview = String(decoding: first.prefix(48), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            return "\(http?.statusCode ?? 0) \(type) \(preview)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}

/// Runs a closure once, from whichever callback gets there first.
private final class Once {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
