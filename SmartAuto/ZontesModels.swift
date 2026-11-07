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

/// One model and colour from the artwork catalog behind the official app's bind screen.
struct MotorStyle: Identifiable, Equatable, Codable {
    let itemCode: String
    let name: String
    let category: String
    let imageURL: URL
    let thumbnailURL: URL?

    var id: String { itemCode }
}

struct MotorCategory: Identifiable, Equatable {
    let name: String
    let styles: [MotorStyle]

    var id: String { name }
}

enum VehicleCommand: String, Identifiable, CaseIterable {
    case lock
    case unlock
    case find
    case seat
    case fuelLid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lock: return "ล็อกรถ"
        case .unlock: return "ปลดล็อกรถ"
        case .find: return "ค้นหารถ"
        case .seat: return "เปิดเบาะ"
        case .fuelLid: return "เปิดฝาถังน้ำมัน"
        }
    }

    var systemImage: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .find: return "location.fill"
        case .seat: return "rectangle.open.vertical"
        case .fuelLid: return "fuelpump.fill"
        }
    }
}

enum ZontesError: LocalizedError {
    case invalidResponse
    case message(String)
    case missingVehicle
    case invalidVehicleKey
    case commandTimedOut
    case commandRejected
    case commandConnectionClosed
    case bluetoothPasswordRejected

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
            return "รถไม่ตอบรับคำสั่งภายในเวลาที่กำหนด กรุณาตรวจสัญญาณแล้วลองใหม่"
        case .commandRejected:
            return "รถปฏิเสธคำสั่ง กรุณารีเฟรชสถานะรถแล้วลองใหม่"
        case .commandConnectionClosed:
            return "การเชื่อมต่อระบบควบคุมรถถูกตัดก่อนรถตอบรับ"
        case .bluetoothPasswordRejected:
            return "รหัส Bluetooth ของรถไม่ถูกต้อง"
        }
    }
}
