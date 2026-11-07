import Foundation

struct ZontesSession: Codable, Equatable {
    let account: String
    let userCode: String
    let signCode: String
    let accessToken: String
    let tokenTime: String
    let carCode: String
    let mcuID: String
    let imsi: String
    let isOwner: Bool
}

struct VehicleLocation: Equatable {
    let latitude: Double
    let longitude: Double
}

struct VehicleSnapshot: Equatable {
    let carCode: String
    let mcuID: String
    let name: String
    let remarkName: String
    let imageURL: URL?
    let isOnline: Bool
    let isLocked: Bool?
    let fuelPercent: Int?
    let rangeKilometers: Int?
    let batteryVoltage: Double?
    let frontTireKPa: Int?
    let rearTireKPa: Int?
    let maintenanceKilometers: Int?
    let satelliteCount: Int?
    let updatedAt: String
    let location: VehicleLocation?

    var displayName: String {
        if !remarkName.isEmpty { return remarkName }
        if !name.isEmpty { return name }
        return carCode.isEmpty ? "ZONTES" : carCode
    }
}

enum VehicleCommand: String, Identifiable, CaseIterable {
    case lock
    case unlock
    case find

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lock: return "ล็อกรถ"
        case .unlock: return "ปลดล็อกรถ"
        case .find: return "ค้นหารถ"
        }
    }

    var systemImage: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .find: return "location.fill"
        }
    }
}

enum ZontesError: LocalizedError {
    case invalidResponse
    case message(String)
    case missingVehicle
    case invalidVehicleKey
    case commandTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "เซิร์ฟเวอร์ตอบกลับในรูปแบบที่ไม่รองรับ"
        case let .message(message):
            return message
        case .missingVehicle:
            return "บัญชีนี้ยังไม่มีรถที่พร้อมใช้งาน"
        case .invalidVehicleKey:
            return "ข้อมูลยืนยันตัวรถไม่ครบ จึงยังส่งคำสั่งไม่ได้"
        case .commandTimedOut:
            return "เชื่อมต่อระบบควบคุมรถไม่สำเร็จ กรุณาลองใหม่"
        }
    }
}
