import Foundation
import Security

enum KeychainStore {
    static func read(_ id: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.agentboard.balance", kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ secret: String, id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.agentboard.balance", kSecAttrAccount as String: id]
        if secret.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; addition[kSecValueData as String] = Data(secret.utf8)
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw ReaderError.message("无法将凭据保存到钥匙串") }
        } else if status != errSecSuccess { throw ReaderError.message("无法更新钥匙串凭据") }
    }
}

// Reject redirects so credentials never follow a balance request onto another host.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor BalanceService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    func query(_ record: ProviderRecord?, custom: ManualAccount?, previous: Balance?) async -> Balance {
        let id = record?.account.id ?? "manual:" + (custom?.id ?? "")
        var result = previous ?? Balance(id: id)
        result.attemptedAt = Date()
        if let custom, let value = custom.staticAmount {
            result.remaining = value; result.unit = custom.unit; result.updatedAt = Date(); result.error = nil; result.isManual = true
            return result
        }
        do {
            let endpoint: String, key: String, kind: String
            if let custom {
                endpoint = custom.endpoint; key = KeychainStore.read(custom.id) ?? ""; kind = "custom"
            } else if let record {
                let credentials = CCReader.credentials(record.config)
                key = credentials.key; kind = record.account.balanceKind
                guard kind != "unsupported" else { throw ReaderError.message("未识别余额接口，可添加自定义查询") }
                guard !key.isEmpty else { throw ReaderError.message("此账号没有可读取的 API 凭据") }
                guard var components = URLComponents(string: credentials.base), components.host != nil else { throw ReaderError.message("账号缺少有效的 API 地址") }
                components.query = nil; components.fragment = nil
                var path = components.path
                while path.hasSuffix("/") { path.removeLast() }
                if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
                components.path = path + (kind == "deepseek" ? "/user/balance" : "/v1/usage")
                endpoint = components.string ?? ""
            } else { throw ReaderError.message("账号不存在") }
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ReaderError.message("余额查询地址必须是 HTTPS，且不包含登录信息") }
            var request = URLRequest(url: url); request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ReaderError.message("服务商返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 1_000_000 { throw ReaderError.message("余额响应过大") } }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else { throw ReaderError.message("余额接口没有返回 JSON 对象") }
            let value: Double, unit: String
            if kind == "deepseek" {
                guard json["is_available"] as? Bool != false, let row = (json["balance_infos"] as? [[String: Any]])?.first, let amount = number(row["total_balance"]) else { throw ReaderError.message("没有可用的余额字段") }
                value = amount; unit = row["currency"] as? String ?? "CNY"
            } else if kind == "sub2api" {
                guard json["isValid"] as? Bool != false else { throw ReaderError.message("服务商标记账号不可用") }
                let body = json["data"] as? [String: Any] ?? json
                guard let amount = number(body["remaining"]) else { throw ReaderError.message("响应缺少 remaining，需配置自定义字段") }
                value = amount; unit = body["unit"] as? String ?? (body["quota"] as? [String: Any])?["unit"] as? String ?? "USD"
            } else {
                guard let amount = number(at: custom?.amountPath ?? "remaining", in: object) else { throw ReaderError.message("找不到指定的余额字段") }
                value = amount; unit = custom?.unit ?? "USD"
            }
            guard value.isFinite else { throw ReaderError.message("余额不是有效数值") }
            result.remaining = value; result.unit = unit; result.updatedAt = Date(); result.error = nil; result.isManual = false
        } catch {
            if let error = error as? ReaderError { result.error = error.localizedDescription }
            else if error is URLError { result.error = "网络连接失败或超时" }
            else { result.error = "无法解析余额响应" }
        }
        return result
    }
    func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
    func number(at path: String, in object: Any) -> Double? {
        var value: Any? = object
        for part in path.split(separator: ".") {
            if let dict = value as? [String: Any] { value = dict[String(part)] }
            else if let array = value as? [Any], let i = Int(part), array.indices.contains(i) { value = array[i] }
            else { return nil }
        }
        return number(value)
    }
}
