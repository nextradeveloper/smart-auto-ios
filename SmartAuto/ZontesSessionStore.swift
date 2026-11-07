import Foundation
import Security

enum ZontesSessionStore {
    private static let service = "com.nextradeveloper.smartauto.zontes"
    private static let account = "active-session"

    static func load() -> ZontesSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(ZontesSession.self, from: data)
    }

    static func save(_ session: ZontesSession) throws {
        let data = try JSONEncoder().encode(session)
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ZontesError.message("บันทึก session ใน Keychain ไม่สำเร็จ (\(status))")
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The model and colour the owner picked for the vehicle artwork, per PKE code.
enum VehicleStyleStore {
    private static func key(_ pke: String) -> String { "vehicleStyle.\(pke)" }

    static func load(pke: String) -> MotorStyle? {
        guard let data = UserDefaults.standard.data(forKey: key(pke)) else { return nil }
        return try? JSONDecoder().decode(MotorStyle.self, from: data)
    }

    static func save(_ style: MotorStyle?, pke: String) {
        guard let style, let data = try? JSONEncoder().encode(style) else {
            UserDefaults.standard.removeObject(forKey: key(pke))
            return
        }
        UserDefaults.standard.set(data, forKey: key(pke))
    }
}
