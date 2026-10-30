import Foundation
import Security

struct CloudConfiguration {
    static let deepSeekDefault = "deepseek-v4.1-flash"
    static let seedreamDefault = "doubao-seedream-5-0-pro-260628"

    /// A blank or whitespace-only stored id falls back to the current default,
    /// so a cleared text field can never reach the provider as an empty model.
    static var seedreamModel: String { stored("seedreamModel") ?? seedreamDefault }
    static var deepSeekModel: String {
        let selected = stored("deepSeekModel")
        return selected == "deepseek-v4-flash" ? deepSeekDefault : (selected ?? deepSeekDefault)
    }

    private static func stored(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum APIKeyStore {
    enum Provider: String { case deepseek, seedream }
    private static var service: String { (Bundle.main.bundleIdentifier ?? "OutdoorPhotoAssistant") + ".cloudKeys" }
    static func read(_ provider: Provider) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, for provider: Provider) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keyError(status) }
            return
        }
        guard !key.contains(where: { $0.isWhitespace }), key.count < 2048 else {
            throw NSError(domain: "APIKeyStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Key格式不正确，请检查空格或换行。"])
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keyError(status) }
    }
    /// The backend session belongs to an older version and is no longer used.
    static func removeLegacyBackendSession() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: "backend"] as CFDictionary)
    }
    private static func keyError(_ status: OSStatus) -> NSError {
        NSError(domain: "APIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法保存Key到系统钥匙串，请解锁设备后重试。"])
    }
}

/// Seedream 输出规格分类。
enum SeedreamResolution: String, CaseIterable, Identifiable, Codable {
    case k15 = "1.5K", k2 = "2K", k3 = "3K", k4 = "4K"
    var id: String { rawValue }
    var longEdge: Int { switch self { case .k15: 1536; case .k2: 2048; case .k3: 3072; case .k4: 4096 } }
    var title: String { switch self { case .k15: "1.5K 省流"; case .k2: "2K 推荐"; case .k3: "3K"; case .k4: "4K 超清" } }
    var detail: String { "长边约 \(longEdge)px" }
}
enum SeedreamFormat: String, CaseIterable, Identifiable, Codable {
    case jpeg, png
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : "PNG" }
    var detail: String { self == .jpeg ? "体积小，通用" : "无损，体积大" }
}
struct SeedreamOutputSettings: Equatable, Codable {
    var resolution: SeedreamResolution = .k2
    var format: SeedreamFormat = .jpeg
    var watermark = true
    var fingerprint: String { "\(resolution.rawValue)/\(format.rawValue)/\(watermark ? "wm" : "nowm")" }
    var summary: String { "\(resolution.rawValue) · \(format.title) · \(watermark ? "加水印" : "无水印")" }
    /// 模型能力门控（以官方文档为准）
    static func capabilities(for model: String) -> (resolutions: [SeedreamResolution], formats: [SeedreamFormat]) {
        let m = model.lowercased()
        if m.contains("5-0-lite") || m.contains("260128") {
            return ([.k2, .k3, .k4], [.jpeg, .png])
        }
        if m.contains("4-5") || m.contains("4-0") {
            return ([.k2, .k4], [.jpeg])
        }
        return ([.k15, .k2], [.jpeg, .png])
    }
}
