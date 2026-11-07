import CryptoKit
import Foundation

final class ZontesAPI {
    static let shared = ZontesAPI()

    private let root = URL(string: "https://m.zontes.com/BoxApp/ABROAD/")!
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Accept-Language": "th-TH,th;q=0.9,en;q=0.8",
            "User-Agent": "ZONTESSmart/65 CFNetwork iOS",
            "X-Requested-With": "XMLHttpRequest",
        ]
        session = URLSession(configuration: configuration)
    }

    func login(account: String, password: String) async throws -> ZontesSession {
        let digest = Insecure.MD5.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let json = try await post(
            "ashx/UserCenter/UserInfo.ashx",
            form: [
                "method": "login",
                "logintype": "SPLogin",
                "name": account.trimmingCharacters(in: .whitespacesAndNewlines),
                "pwd": digest,
                "language": "en",
            ]
        )

        guard string(json, "result").lowercased() == "success" else {
            throw ZontesError.message(string(json, "failMsg", fallback: "เข้าสู่ระบบไม่สำเร็จ"))
        }
        let accessToken = string(json, "accessToken")
        guard !accessToken.isEmpty else { throw ZontesError.invalidResponse }

        return ZontesSession(
            account: account,
            userCode: string(json, "UserCode", fallback: account),
            signCode: string(json, "SignCode"),
            accessToken: accessToken,
            tokenTime: string(json, "tokenTime"),
            carCode: string(json, "MyMotorCode"),
            mcuID: string(json, "mcuid"),
            imsi: string(json, "imsi"),
            isOwner: bool(json, "isMyPke")
        )
    }

    func vehicle(session current: ZontesSession) async throws -> VehicleSnapshot {
        let json = try await post(
            "ashx/Index/Index.ashx",
            form: [
                "method": "getIndex",
                "ACCESSTOKEN": current.accessToken,
                "language": "en",
            ]
        )

        let failure = string(json, "failMsg")
        if !failure.isEmpty { throw ZontesError.message(failure) }
        guard let car = dictionary(json["myCarData"]) else {
            throw ZontesError.missingVehicle
        }

        let imageBase = string(json, "imgPath", fallback: "https://www.sharpon.com/Tayoimg")
        // IndexImg is the account's vehicle artwork. NameImg can be a model-name graphic (for
        // example, a large “G368” wordmark), not a motorcycle. The official app shows the model
        // and colour picked while binding instead, which only that phone knows; the owner can
        // pick the same one from motorCatalog().
        let imageName = string(car, "IndexImg", fallback: string(car, "NameImg"))
        let locationJSON = array(json["CarLocation"]).first.flatMap { dictionary($0) }
        let rawVoltage = double(car, "Voltage")

        return VehicleSnapshot(
            carCode: string(car, "PKECode", fallback: string(car, "CarCode", fallback: current.carCode)),
            mcuID: string(car, "mcuid", fallback: current.mcuID),
            name: string(car, "ItemName", fallback: string(car, "MotorName")),
            remarkName: string(car, "RemarkName", fallback: string(car, "remarkName")),
            imageURL: vehicleImageURL(base: imageBase, name: imageName),
            isOnline: string(json, "iState") == "1",
            isLocked: optionalInt(car, "Lock").map { $0 == 0 },
            fuelPercent: optionalInt(car, "Oil"),
            rangeKilometers: optionalInt(car, "Range"),
            batteryVoltage: rawVoltage.map { $0 > 30 ? $0 / 10 : $0 },
            frontTireKPa: optionalInt(car, "PressureFront").map { $0 * 2 },
            rearTireKPa: optionalInt(car, "PressureRear").map { $0 * 2 },
            maintenanceKilometers: optionalInt(car, "MaintenanceMileage"),
            satelliteCount: optionalInt(car, "SatelliteNum"),
            updatedAt: string(car, "UTCChangeTime"),
            location: locationJSON.flatMap {
                guard let latitude = double($0, "Latitude"),
                      let longitude = double($0, "Longitude")
                else { return nil }
                return VehicleLocation(latitude: latitude, longitude: longitude)
            }
        )
    }

    /// Model and colour artwork offered by the official app's bind screen. The official app
    /// asks with the model-family code from the PKE's QR label; the service groups those codes
    /// by tens, and 001, 010 and 020 cover every family it lists.
    func motorCatalog() async throws -> [MotorCategory] {
        async let gSeries = try? motorCategories(code: "020")
        async let large = try? motorCategories(code: "001")
        async let scooters = try? motorCategories(code: "010")
        let groups = [await gSeries, await large, await scooters].compactMap { $0 }
        guard !groups.isEmpty else {
            throw ZontesError.message("โหลดรายการรุ่นรถไม่สำเร็จ กรุณาตรวจสอบอินเทอร์เน็ตแล้วลองใหม่")
        }
        var seen = Set<String>()
        return groups.flatMap { $0 }.filter { seen.insert($0.name).inserted }
    }

    private func motorCategories(code: String) async throws -> [MotorCategory] {
        let url = URL(string: "https://tayo.zontesmotor.com/zontespkeapp/api/GX/PKE/MotorImg/getMotorType/\(code)")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              optionalInt(json, "code") == 200
        else { throw ZontesError.invalidResponse }

        return array(json["data"]).compactMap { dictionary($0) }.compactMap { category -> MotorCategory? in
            let name = string(category, "categoryType").trimmingCharacters(in: .whitespacesAndNewlines)
            let base = string(category, "imagePath")
            var seen = Set<String>()
            let styles = array(category["gxpkeMotorImgs"]).compactMap { dictionary($0) }.compactMap { item -> MotorStyle? in
                let itemCode = string(item, "itemCode")
                guard !itemCode.isEmpty, seen.insert(itemCode).inserted,
                      let image = catalogImageURL(base: base, name: string(item, "indexImg"))
                else { return nil }
                let title = string(item, "enItemName", fallback: string(item, "itemName"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return MotorStyle(
                    itemCode: itemCode,
                    name: title.isEmpty ? itemCode : title,
                    category: name,
                    imageURL: image,
                    thumbnailURL: catalogImageURL(base: base, name: string(item, "smallImg"))
                )
            }
            return name.isEmpty || styles.isEmpty ? nil : MotorCategory(name: name, styles: styles)
        }
    }

    private func catalogImageURL(base: String, name: String) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let absolute = URL(string: name), absolute.scheme != nil { return absolute }
        let cleanBase = base.isEmpty ? "https://www.sharpon.com/Tayoimg/GX/Box/MotorPic" : base
        return URL(string: cleanBase.hasSuffix("/") ? cleanBase + name : cleanBase + "/" + name)
    }

    private func post(_ path: String, form: [String: String]) async throws -> [String: Any] {
        let url = root.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw ZontesError.message("เซิร์ฟเวอร์ ZONTES ไม่ตอบสนอง หากเชื่อมต่อ Wi-Fi ของรถอยู่ ให้ลองปิด Wi-Fi แล้วเข้าสู่ระบบผ่าน 4G/5G")
            case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost:
                throw ZontesError.message("เชื่อมต่อเซิร์ฟเวอร์ ZONTES ไม่ได้ กรุณาตรวจสอบอินเทอร์เน็ตแล้วลองใหม่")
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw ZontesError.message("ระบบ ZONTES ไม่พร้อมใช้งาน")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZontesError.invalidResponse
        }
        return object
    }

    private func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func vehicleImageURL(base: String, name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        if let absolute = URL(string: name), absolute.scheme != nil { return absolute }
        let cleanBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(cleanBase)/GX/Box/MotorPic/\(name)")
    }
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func array(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func string(_ json: [String: Any], _ key: String, fallback: String = "") -> String {
    guard let value = json[key], !(value is NSNull) else { return fallback }
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return fallback
}

private func optionalInt(_ json: [String: Any], _ key: String) -> Int? {
    guard let value = json[key], !(value is NSNull) else { return nil }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String, let number = Double(value) { return Int(number) }
    return nil
}

private func double(_ json: [String: Any], _ key: String) -> Double? {
    guard let value = json[key], !(value is NSNull) else { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func bool(_ json: [String: Any], _ key: String) -> Bool {
    let value = string(json, key).lowercased()
    return value == "true" || value == "1"
}
