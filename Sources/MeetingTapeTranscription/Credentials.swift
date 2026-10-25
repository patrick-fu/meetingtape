import Foundation
import Security

public struct DoubaoCredential: Codable, Sendable {
    public var apiKey: String
    public var appID: String
    public var accessToken: String
    public init(apiKey: String = "", appID: String = "", accessToken: String = "") {
        self.apiKey = apiKey; self.appID = appID; self.accessToken = accessToken
    }
    var valid: Bool { !apiKey.isEmpty || (!appID.isEmpty && !accessToken.isEmpty) }
}

public enum TranscriptionCredentials {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.paaatrickfu.meetingtape.transcription", kSecAttrAccount as String: "doubao"] }

    public static func save(_ value: DoubaoCredential) throws {
        guard value.valid else { throw TranscriptionFailure("请输入 API Key，或完整的 App ID 与 Access Token。") }
        let data = try JSONEncoder().encode(value)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        let status = updated == errSecItemNotFound ? SecItemAdd(item as CFDictionary, nil) : updated
        guard status == errSecSuccess else { throw TranscriptionFailure("无法将凭据保存到钥匙串（\(status)）。") }
    }
    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranscriptionFailure("无法移除凭据（\(status)）。") }
    }
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DoubaoCredential {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try JSONDecoder().decode(DoubaoCredential.self, from: data) }
        if status != errSecItemNotFound { throw TranscriptionFailure("无法读取钥匙串凭据（\(status)）。") }
        let value = DoubaoCredential(apiKey: environment["DOUBAO_API_KEY"] ?? "", appID: environment["DOUBAO_APPID"] ?? "", accessToken: environment["DOUBAO_ACCESS_TOKEN"] ?? "")
        guard value.valid else { throw TranscriptionFailure("请先在设置中配置豆包凭据。") }
        return value
    }
    public static func configured() -> Bool { (try? load())?.valid == true }
}
