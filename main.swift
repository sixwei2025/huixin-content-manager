import AppKit
import SwiftUI
import Security
import CryptoKit

struct WeChatSummary {
    var followers: Int = 0
    var newFollowers: Int = 0
    var articleReads: Int = 0
    var articleShares: Int = 0
    var updatedAt = Date()
}

struct WeChatDraft: Identifiable {
    let id: String
    let title: String
    let updateTime: Date?
    let articleCount: Int
}

struct XSummary {
    var followers: Int = 0
    var following: Int = 0
    var posts: Int = 0
}

struct BiliSummary {
    var name: String
    var openID: String
}

struct XHSSummary {
    var nickname: String
    var openID: String
}

struct DouyinSummary {
    var totalIssue: Int
    var newIssue: Int
    var newPlay: Int
    var totalFans: Int
    var newFans: Int
}

struct CreatorWorkItem: Codable {
    let title: String
    let platform: String
    let status: String
    let views: String
    let likes: String
}

struct CreatorPlatformSnapshot: Codable {
    let platform: String
    let key: String
    let ok: Bool
    let need_login: Bool?
    let source: String?
    let updated_at: String?
    let account: String?
    let followers: Int?
    let delta: Int?
    let posts: Int?
    let views: Int?
    let likes: Int?
    let comments: Int?
    let shares: Int?
    let saves: Int?
    let items: [CreatorWorkItem]?
    let message: String?

    var engagementText: String {
        guard let views, views > 0 else { return "—" }
        let interactions = (likes ?? 0) + (comments ?? 0) + (shares ?? 0) + (saves ?? 0)
        return String(format: "%.1f%%", Double(interactions) / Double(views) * 100)
    }
}

final class CreatorBridge {
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".huixin-content-manager/cache/platform_metrics.json")

    private func pythonPath() -> String {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GrokBridge/视频号/venv/bin/python").path,
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    private func scriptPath() -> String? {
        if let res = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: res).appendingPathComponent("creator_bridge.py").path
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        let repo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Workbuddy/github-skills-14/huixin-content-manager/server/creator_bridge.py").path
        return FileManager.default.fileExists(atPath: repo) ? repo : nil
    }

    func loadCached() -> [String: CreatorPlatformSnapshot] {
        guard let data = try? Data(contentsOf: cacheURL),
              let dict = try? JSONDecoder().decode([String: CreatorPlatformSnapshot].self, from: data) else {
            return [:]
        }
        return dict
    }

    func run(args: [String]) async -> Data? {
        guard let script = scriptPath() else { return nil }
        let python = pythonPath()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: python)
                proc.arguments = [script] + args
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func sync(platform: String) async -> CreatorPlatformSnapshot? {
        guard let data = await run(args: ["sync", "--platform", platform]) else { return nil }
        return try? JSONDecoder().decode(CreatorPlatformSnapshot.self, from: data)
    }

    func syncAll() async -> [String: CreatorPlatformSnapshot] {
        guard let data = await run(args: ["sync", "--platform", "all"]),
              let dict = try? JSONDecoder().decode([String: CreatorPlatformSnapshot].self, from: data) else {
            return [:]
        }
        return dict
    }

    func login(platform: String) async -> CreatorPlatformSnapshot? {
        guard let data = await run(args: ["login", "--platform", platform]) else { return nil }
        return try? JSONDecoder().decode(CreatorPlatformSnapshot.self, from: data)
    }

    func keepalive() async {
        _ = await run(args: ["keepalive"])
    }
}

final class ProfileVault {
    private let service = "cn.huixin.contentmanager.profile"

    func saved() -> (phone: String, email: String, company: String, contact: String)? {
        let phone = read("phone") ?? ""
        let email = read("email") ?? ""
        let company = read("company") ?? ""
        let contact = read("contact") ?? ""
        guard !phone.isEmpty || !email.isEmpty || !company.isEmpty || !contact.isEmpty else { return nil }
        return (phone, email, company, contact)
    }

    func save(phone: String, email: String, company: String, contact: String) {
        write(phone, key: "phone")
        write(email, key: "email")
        write(company, key: "company")
        write(contact, key: "contact")
    }

    private func write(_ value: String, key: String) {
        let data = Data(value.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil)
    }

    private func read(_ key: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum WeChatConnectorError: LocalizedError {
    case missingCredentials
    case api(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请先填写公众号 AppID 和 AppSecret"
        case .api(let message): return message
        }
    }
}

final class WeChatConnector {
    private let relayURL = "http://127.0.0.1:18848/wechat"
    private let service = "cn.huixin.contentmanager.wechat"
    private let accountKey = "account"
    private let secretKey = "secret"

    func savedCredentials() -> (String, String)? {
        guard let account = read(accountKey), let secret = read(secretKey), !account.isEmpty, !secret.isEmpty else { return nil }
        return (account, secret)
    }

    func saveCredentials(appID: String, secret: String) {
        write(appID, key: accountKey); write(secret, key: secretKey)
    }

    func fetchSummary(appID: String, secret: String) async throws -> WeChatSummary {
        do { return try await fetchSummaryDirect(appID: appID, secret: secret) }
        catch let error as WeChatConnectorError where error.errorDescription?.contains("白名单") == true {
            return try await relaySummary(appID: appID, secret: secret)
        }
    }

    private func fetchSummaryDirect(appID: String, secret: String) async throws -> WeChatSummary {
        guard !appID.isEmpty, !secret.isEmpty else { throw WeChatConnectorError.missingCredentials }
        var tokenURL = URLComponents(string: "https://api.weixin.qq.com/cgi-bin/token")!
        tokenURL.queryItems = [URLQueryItem(name: "grant_type", value: "client_credential"), URLQueryItem(name: "appid", value: appID), URLQueryItem(name: "secret", value: secret)]
        let (tokenData, _) = try await URLSession.shared.data(from: tokenURL.url!)
        let tokenJSON = try json(tokenData)
        guard let token = tokenJSON["access_token"] as? String else {
            if let code = tokenJSON["errcode"] as? Int, code == 40164 {
                throw WeChatConnectorError.api("微信凭证已识别，但当前出口 IP 不在公众号白名单中。请将本机当前出口 IP 加入白名单后重试。")
            }
            throw WeChatConnectorError.api(tokenJSON["errmsg"] as? String ?? "公众号授权失败")
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"; date.locale = Locale(identifier: "en_US_POSIX")
        let day = date.string(from: yesterday)
        let user = try await postJSON("https://api.weixin.qq.com/datacube/getusersummary?access_token=\(token)", body: ["begin_date": day, "end_date": day])
        let cumulate = try await postJSON("https://api.weixin.qq.com/datacube/getusercumulate?access_token=\(token)", body: ["begin_date": day, "end_date": day])
        let article = try await postJSON("https://api.weixin.qq.com/datacube/getarticlesummary?access_token=\(token)", body: ["begin_date": day, "end_date": day])
        let read = try await postJSON("https://api.weixin.qq.com/datacube/getuserread?access_token=\(token)", body: ["begin_date": day, "end_date": day])
        func sum(_ object: [String: Any], _ keys: [String]) -> Int { keys.compactMap { object[$0] as? Int }.reduce(0, +) }
        let userRows = user["list"] as? [[String: Any]] ?? []
        let cumulateRows = cumulate["list"] as? [[String: Any]] ?? []
        let articleRows = article["list"] as? [[String: Any]] ?? []
        let readRows = read["list"] as? [[String: Any]] ?? []
        var summary = WeChatSummary()
        summary.newFollowers = userRows.map { ($0["new_user"] as? Int ?? 0) - ($0["cancel_user"] as? Int ?? 0) }.reduce(0, +)
        summary.followers = cumulateRows.last?["cumulate_user"] as? Int ?? 0
        summary.articleReads = articleRows.map { sum($0, ["int_page_read_count", "ori_page_read_count"]) }.reduce(0, +)
        summary.articleShares = readRows.map { sum($0, ["share_count", "add_to_fav_count"]) }.reduce(0, +)
        return summary
    }

    func fetchDrafts(appID: String, secret: String) async throws -> [WeChatDraft] {
        do { return try await fetchDraftsDirect(appID: appID, secret: secret) }
        catch let error as WeChatConnectorError where error.errorDescription?.contains("白名单") == true {
            return try await relayDrafts(appID: appID, secret: secret)
        }
    }

    private func fetchDraftsDirect(appID: String, secret: String) async throws -> [WeChatDraft] {
        guard !appID.isEmpty, !secret.isEmpty else { throw WeChatConnectorError.missingCredentials }
        let token = try await accessToken(appID: appID, secret: secret)
        let result = try await postJSON("https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token=\(token)", body: ["offset": "0", "count": "20", "no_content": "1"])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return (result["item"] as? [[String: Any]] ?? []).compactMap { item in
            guard let mediaID = item["media_id"] as? String else { return nil }
            let content = item["content"] as? [String: Any]
            let news = content?["news_item"] as? [[String: Any]] ?? []
            let title = news.first?["title"] as? String ?? "未命名草稿"
            let timestamp = item["update_time"] as? Int
            return WeChatDraft(id: mediaID, title: title, updateTime: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }, articleCount: news.count)
        }
    }

    private func relaySummary(appID: String, secret: String) async throws -> WeChatSummary {
        let result = try await relay(action: "summary", appID: appID, secret: secret)
        guard let data = result["data"] as? [String: Any] else { throw WeChatConnectorError.api(result["error"] as? String ?? "腾讯云中继返回错误") }
        return WeChatSummary(followers: data["followers"] as? Int ?? 0, newFollowers: data["newFollowers"] as? Int ?? 0, articleReads: data["articleReads"] as? Int ?? 0, articleShares: data["articleShares"] as? Int ?? 0)
    }

    private func relayDrafts(appID: String, secret: String) async throws -> [WeChatDraft] {
        let result = try await relay(action: "drafts", appID: appID, secret: secret)
        guard let data = result["data"] as? [[String: Any]] else { throw WeChatConnectorError.api(result["error"] as? String ?? "腾讯云中继返回错误") }
        return data.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let timestamp = item["updateTime"] as? Int
            return WeChatDraft(id: id, title: item["title"] as? String ?? "未命名草稿", updateTime: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }, articleCount: item["articleCount"] as? Int ?? 0)
        }
    }

    private func relay(action: String, appID: String, secret: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: relayURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "appID": appID, "secret": secret])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try json(data)
    }

    private func accessToken(appID: String, secret: String) async throws -> String {
        var tokenURL = URLComponents(string: "https://api.weixin.qq.com/cgi-bin/token")!
        tokenURL.queryItems = [URLQueryItem(name: "grant_type", value: "client_credential"), URLQueryItem(name: "appid", value: appID), URLQueryItem(name: "secret", value: secret)]
        let (tokenData, _) = try await URLSession.shared.data(from: tokenURL.url!)
        let tokenJSON = try json(tokenData)
        guard let token = tokenJSON["access_token"] as? String else {
            if let code = tokenJSON["errcode"] as? Int, code == 40164 {
                throw WeChatConnectorError.api("微信凭证已识别，但当前出口 IP 不在公众号白名单中。请将本机当前出口 IP 加入白名单后重试。")
            }
            throw WeChatConnectorError.api(tokenJSON["errmsg"] as? String ?? "公众号授权失败")
        }
        return token
    }

    private func postJSON(_ url: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try json(data)
        if let code = result["errcode"] as? Int, code != 0 {
            if code == 48001 {
                throw WeChatConnectorError.api("公众号凭证有效，但当前账号没有这项接口权限。GitHub 上的多个公众号工具也将个人未认证号的统计接口标为不可用；可继续使用 CSV 导入，认证号开通数据统计权限后再接入。")
            }
            throw WeChatConnectorError.api(result["errmsg"] as? String ?? "公众号数据接口返回错误")
        }
        return result
    }

    private func json(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
    private func write(_ value: String, key: String) { let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil) }
    private func read(_ key: String) -> String? { var result: AnyObject?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result); guard status == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
}

enum XConnectorError: LocalizedError {
    case missingCredentials
    case api(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请填写 X 用户名和 Bearer Token"
        case .api(let message): return message
        }
    }
}

final class XConnector {
    private let service = "cn.huixin.contentmanager.x"

    func savedCredentials() -> (String, String)? {
        guard let username = read("username"), let token = read("token"), !username.isEmpty, !token.isEmpty else { return nil }
        return (username, token)
    }

    func saveCredentials(username: String, token: String) {
        write(username, key: "username"); write(token, key: "token")
    }

    func fetchSummary(username: String, token: String) async throws -> XSummary {
        guard !username.isEmpty, !token.isEmpty else { throw XConnectorError.missingCredentials }
        var components = URLComponents(string: "https://api.x.com/2/users/by/username/\(username)")!
        components.queryItems = [URLQueryItem(name: "user.fields", value: "public_metrics")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let user = result["data"] as? [String: Any] else {
            let errors = (result["errors"] as? [[String: Any]])?.first?["detail"] as? String
            throw XConnectorError.api(errors ?? "X API 返回了无法识别的结果，请检查 Token 权限")
        }
        let metrics = user["public_metrics"] as? [String: Any] ?? [:]
        return XSummary(followers: metrics["followers_count"] as? Int ?? 0, following: metrics["following_count"] as? Int ?? 0, posts: metrics["tweet_count"] as? Int ?? 0)
    }

    private func write(_ value: String, key: String) { let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil) }
    private func read(_ key: String) -> String? { var result: AnyObject?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result); guard status == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
}

enum BiliConnectorError: LocalizedError {
    case missingCredentials
    case api(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请填写 B 站 Access Key、App Secret 和 Access Token"
        case .api(let message): return message
        }
    }
}

final class BiliConnector {
    private let service = "cn.huixin.contentmanager.bilibili"

    func savedCredentials() -> (String, String, String)? {
        guard let key = read("accessKey"), let secret = read("secret"), let token = read("token"), !key.isEmpty, !secret.isEmpty, !token.isEmpty else { return nil }
        return (key, secret, token)
    }

    func saveCredentials(accessKey: String, secret: String, token: String) {
        write(accessKey, key: "accessKey"); write(secret, key: "secret"); write(token, key: "token")
    }

    func fetchProfile(accessKey: String, secret: String, token: String) async throws -> BiliSummary {
        guard !accessKey.isEmpty, !secret.isEmpty, !token.isEmpty else { throw BiliConnectorError.missingCredentials }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let contentMD5 = Insecure.MD5.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let xHeaders = [
            "x-bili-accesskeyid": accessKey,
            "x-bili-content-md5": contentMD5,
            "x-bili-signature-method": "HMAC-SHA256",
            "x-bili-signature-nonce": nonce,
            "x-bili-signature-version": "2.0",
            "x-bili-timestamp": timestamp
        ]
        let signingText = xHeaders.keys.sorted().map { "\($0):\(xHeaders[$0]!)" }.joined(separator: "\n")
        let digest = HMAC<SHA256>.authenticationCode(for: Data(signingText.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let authorization = digest.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://member.bilibili.com/arcopen/fn/user/account/info")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Access-Token")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in xHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (result["code"] as? Int ?? -1) == 0, let profile = result["data"] as? [String: Any] else {
            throw BiliConnectorError.api(result["message"] as? String ?? "B 站官方接口返回错误，请检查应用签名和授权权限")
        }
        return BiliSummary(name: profile["name"] as? String ?? "已授权账号", openID: profile["openid"] as? String ?? "")
    }

    private func write(_ value: String, key: String) { let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil) }
    private func read(_ key: String) -> String? { var result: AnyObject?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result); guard status == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
}

enum XHSConnectorError: LocalizedError {
    case missingCredentials
    case api(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请填写小红书 App ID 和 OAuth Access Token"
        case .api(let message): return message
        }
    }
}

final class XHSConnector {
    private let service = "cn.huixin.contentmanager.xhs"

    func savedCredentials() -> (String, String)? {
        guard let appID = read("appID"), let token = read("token"), !appID.isEmpty, !token.isEmpty else { return nil }
        return (appID, token)
    }

    func saveCredentials(appID: String, token: String) { write(appID, key: "appID"); write(token, key: "token") }

    func fetchUser(appID: String, token: String) async throws -> XHSSummary {
        guard !appID.isEmpty, !token.isEmpty else { throw XHSConnectorError.missingCredentials }
        var request = URLRequest(url: URL(string: "https://openaccount.xiaohongshu.com/api/sns/v1/oauth2/batch_get_min_user_info")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (result["code"] as? Int ?? -1) == 0, let profile = result["data"] as? [String: Any] else {
            throw XHSConnectorError.api(result["msg"] as? String ?? "小红书官方接口返回错误，请检查 App ID 和授权 Token")
        }
        return XHSSummary(nickname: profile["nickname"] as? String ?? "已授权账号", openID: profile["open_id"] as? String ?? "")
    }

    private func write(_ value: String, key: String) { let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil) }
    private func read(_ key: String) -> String? { var result: AnyObject?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result); guard status == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
}

enum DouyinConnectorError: LocalizedError {
    case missingCredentials
    case api(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请填写抖音 open_id 和 OAuth Access Token"
        case .api(let message): return message
        }
    }
}

final class DouyinConnector {
    private let service = "cn.huixin.contentmanager.douyin"

    func savedCredentials() -> (String, String)? {
        guard let openID = read("openID"), let token = read("token"), !openID.isEmpty, !token.isEmpty else { return nil }
        return (openID, token)
    }

    func saveCredentials(openID: String, token: String) { write(openID, key: "openID"); write(token, key: "token") }

    func fetchSummary(openID: String, token: String) async throws -> DouyinSummary {
        guard !openID.isEmpty, !token.isEmpty else { throw DouyinConnectorError.missingCredentials }
        var components = URLComponents(string: "https://open.douyin.com/data/external/user/item/")!
        components.queryItems = [URLQueryItem(name: "open_id", value: openID), URLQueryItem(name: "date_type", value: "30")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "access-token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let dataObject = result["data"] as? [String: Any] ?? [:]
        guard let rows = dataObject["result_list"] as? [[String: Any]], let last = rows.last else {
            throw DouyinConnectorError.api(dataObject["description"] as? String ?? "抖音官方接口返回错误，请检查授权权限")
        }
        func number(_ value: Any?) -> Int { if let value = value as? Int { return value }; return Int(String(describing: value ?? "0")) ?? 0 }
        let fans = try await fetchMetric(path: "fans", openID: openID, token: token)
        return DouyinSummary(totalIssue: number(last["total_issue"]), newIssue: number(last["new_issue"]), newPlay: number(last["new_play"]), totalFans: number(fans["total_fans"]), newFans: number(fans["new_fans"]))
    }

    private func fetchMetric(path: String, openID: String, token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://open.douyin.com/data/external/user/\(path)/")!
        components.queryItems = [URLQueryItem(name: "open_id", value: openID), URLQueryItem(name: "date_type", value: "30")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "access-token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let dataObject = result["data"] as? [String: Any] ?? [:]
        guard let rows = dataObject["result_list"] as? [[String: Any]], let last = rows.last else {
            throw DouyinConnectorError.api(dataObject["description"] as? String ?? "抖音粉丝接口返回错误，请检查 data.external.user 权限")
        }
        return last
    }

    private func write(_ value: String, key: String) { let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary); SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data] as CFDictionary, nil) }
    private func read(_ key: String) -> String? { var result: AnyObject?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecReturnData: true] as CFDictionary, &result); guard status == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8) }
}

struct Platform: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let color: Color
    let followers: String
    let delta: String
    let posts: String
    let engagement: String
    let source: String
}

struct ContentItem: Identifiable {
    let id = UUID()
    let title: String
    let platform: String
    let status: String
    let views: String
    let likes: String
    let conversion: String
    let color: Color
}

struct PlatformConnection: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let state: String
    let detail: String
    let color: Color
    let docsURL: String?
}

struct ImportedPlatformMetrics: Codable {
    var followers: Int?
    var delta: Int?
    var posts: Int?
    var views: Int?
    var likes: Int?
    var comments: Int?
    var shares: Int?
    var saves: Int?

    var engagement: String {
        guard let views, views > 0 else { return "—" }
        let interactions = (likes ?? 0) + (comments ?? 0) + (shares ?? 0) + (saves ?? 0)
        return String(format: "%.1f%%", Double(interactions) / Double(views) * 100)
    }
}

struct ImportedPlatformSnapshot: Codable {
    let count: Int
    let metrics: ImportedPlatformMetrics
}

@MainActor final class ContentStore: ObservableObject {
    @Published var selectedTab = "总览"
    @Published var lastUpdated = Date()
    @Published var refreshing = false
    @Published var wechatSummary: WeChatSummary?
    @Published var wechatDrafts: [WeChatDraft] = []
    @Published var wechatDraftStatus = "尚未读取草稿箱"
    @Published var xSummary: XSummary?
    @Published var xStatus = "尚未连接"
    @Published var xhsSummary: XHSSummary?
    @Published var xhsStatus = "尚未连接"
    @Published var douyinSummary: DouyinSummary?
    @Published var douyinStatus = "尚未连接"
    @Published var channelsStatus = "尚未连接"
    @Published var channelsHuixinStatus = "尚未连接"
    @Published var channelsShanheStatus = "尚未连接"
    @Published var wechatStatus = "尚未连接"
    @Published var creatorSnapshots: [String: CreatorPlatformSnapshot] = [:]
    @Published var syncingCreatorKey: String?
    @Published var importedCounts: [String: Int] = [:]
    @Published var importedMetrics: [String: ImportedPlatformMetrics] = [:]
    @Published var dataSource = "演示数据 · 尚未连接平台"
    @Published var vaultStatus = "未设置"
    private let vault = ProfileVault()
    private let wechat = WeChatConnector()
    private let x = XConnector()
    private let xhs = XHSConnector()
    private let douyin = DouyinConnector()
    private let bridge = CreatorBridge()
    private let importedDataKey = "cn.huixin.contentmanager.imported-platform-data"
    private let importedCSVPathsKey = "cn.huixin.contentmanager.imported-csv-paths"
    var importedCSVPaths: [String: String] = [:]
    private var importedCSVModifiedDates: [String: Date] = [:]
    private var csvRefreshTimer: Timer?
    private var keepaliveTimer: Timer?

    init() {
        if vault.saved() != nil { vaultStatus = "已保存到本机钥匙串" }
        if let data = UserDefaults.standard.data(forKey: importedDataKey),
           let snapshots = try? JSONDecoder().decode([String: ImportedPlatformSnapshot].self, from: data) {
            importedCounts = snapshots.mapValues(\.count)
            importedMetrics = snapshots.mapValues(\.metrics)
            if !snapshots.isEmpty { dataSource = "包含已保存的手动导入数据 · 未连接平台不显示为真实数据" }
        }
        importedCSVPaths = UserDefaults.standard.dictionary(forKey: importedCSVPathsKey) as? [String: String] ?? [:]
        // 启动时先读取上一次选择的文件；之后每分钟检查修改时间，行为和 Token 管家的自动刷新一致。
        refreshSavedCSVFiles(force: true)
        csvRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSavedCSVFiles() }
        }
        // 每 30 分钟静默保活已登录的创作者中心会话（视频号/公众号/抖音/小红书），延长登录有效期
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                await self.bridge.keepalive()
                let refreshed = self.bridge.loadCached()
                await MainActor.run {
                    for (_, snap) in refreshed where snap.ok {
                        self.applyCreatorSnapshot(snap)
                    }
                }
            }
        }
        if wechat.savedCredentials() != nil { wechatStatus = "已保存凭证 · 点击更新" }
        if x.savedCredentials() != nil { xStatus = "已保存凭证 · 点击更新" }
        if xhs.savedCredentials() != nil { xhsStatus = "已保存凭证 · 点击更新" }
        if douyin.savedCredentials() != nil { douyinStatus = "已保存凭证 · 点击更新" }
        let cached = bridge.loadCached()
        for (_, snap) in cached where snap.ok {
            applyCreatorSnapshot(snap)
        }
    }

    func savedProfile() -> (phone: String, email: String, company: String, contact: String) {
        vault.saved() ?? ("", "", "", "")
    }

    func saveProfile(phone: String, email: String, company: String, contact: String) {
        vault.save(phone: phone, email: email, company: company, contact: contact)
        vaultStatus = "已保存到本机钥匙串"
    }

    let tabs = ["总览", "内容", "平台", "复盘"]
    let connections: [PlatformConnection] = [
        .init(name: "微信公众号", symbol: "bubble.left.and.bubble.right.fill", state: "创作者中心直连", detail: "支持扫码直连公众平台，或配置 AppID/AppSecret 读取草稿箱", color: .green, docsURL: "https://mp.weixin.qq.com/"),
        .init(name: "抖音", symbol: "music.note", state: "创作者中心直连", detail: "支持扫码直连抖音创作者中心，无需企业开放平台审核", color: .black, docsURL: "https://creator.douyin.com/"),
        .init(name: "视频号 · 袁六伟", symbol: "play.rectangle.fill", state: "创作者中心直连", detail: "主号 · AI 相关内容（自动探测本机或扫码登录）", color: .orange, docsURL: "https://channels.weixin.qq.com/platform"),
        .init(name: "视频号 · 汇芯袁总", symbol: "play.rectangle.fill", state: "创作者中心直连", detail: "二号 · 汇芯袁总（独立扫码会话）", color: .orange, docsURL: "https://channels.weixin.qq.com/platform"),
        .init(name: "视频号 · 山河来电", symbol: "play.rectangle.fill", state: "创作者中心直连", detail: "三号 · 山河来电（独立扫码会话）", color: .orange, docsURL: "https://channels.weixin.qq.com/platform"),
        .init(name: "小红书", symbol: "note.text", state: "创作者中心直连", detail: "支持扫码直连小红书创作者平台，或使用 CSV 自动同步", color: .red, docsURL: "https://creator.xiaohongshu.com/"),
        .init(name: "X / Twitter", symbol: "at", state: "官方 API", detail: "使用 X Developer User Bearer Token 读取公开指标", color: .primary, docsURL: "https://developer.x.com/")
    ]
    let platforms: [Platform] = [
        .init(name: "公众号", symbol: "bubble.left.and.bubble.right.fill", color: .green, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "小红书", symbol: "note.text", color: .red, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "视频号 · 袁六伟", symbol: "play.rectangle.fill", color: .orange, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "视频号 · 汇芯袁总", symbol: "play.rectangle.fill", color: .orange, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "视频号 · 山河来电", symbol: "play.rectangle.fill", color: .orange, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "抖音", symbol: "music.note", color: .black, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "X", symbol: "at", color: .primary, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接"),
        .init(name: "知识星球", symbol: "person.3.fill", color: .purple, followers: "—", delta: "—", posts: "—", engagement: "—", source: "待连接")
    ]

    var displayPlatforms: [Platform] {
        platforms.map { item in
            let snap = creatorSnapshots[item.name] ?? (item.name == "视频号 · 袁六伟" ? creatorSnapshots["视频号"] : nil)
            if let snap, snap.ok {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: snap.followers.map(format) ?? "—",
                                delta: snap.delta.map { $0 >= 0 ? "+\(format($0))" : format($0) } ?? "—",
                                posts: snap.posts.map(format) ?? "—",
                                engagement: snap.engagementText,
                                source: snap.source ?? "\(item.name)创作者中心")
            }
            if let imported = importedMetrics[item.name] {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: imported.followers.map(format) ?? "—",
                                delta: imported.delta.map { $0 >= 0 ? "+\(format($0))" : format($0) } ?? "—",
                                posts: imported.posts.map(format) ?? "—",
                                engagement: imported.engagement, source: "CSV 导入")
            }
            if item.name == "X", let summary = xSummary {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: format(summary.followers), delta: "—",
                                posts: format(summary.posts), engagement: "—", source: "X 官方")
            }
            if item.name == "抖音", let summary = douyinSummary {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: format(summary.totalFans), delta: summary.newFans >= 0 ? "+\(format(summary.newFans))" : format(summary.newFans),
                                posts: format(summary.totalIssue), engagement: "—", source: "抖音官方")
            }
            guard item.name == "公众号", let summary = wechatSummary else { return item }
            return Platform(name: item.name, symbol: item.symbol, color: item.color,
                            followers: format(summary.followers),
                            delta: summary.newFollowers >= 0 ? "+\(format(summary.newFollowers))" : format(summary.newFollowers),
                            posts: item.posts, engagement: item.engagement, source: "公众号官方")
        }
    }

    var displayContents: [ContentItem] {
        let colorMap: [String: Color] = ["公众号": .green, "小红书": .red, "视频号": .orange, "抖音": .black]
        var realItems: [ContentItem] = []
        for snap in creatorSnapshots.values where snap.ok {
            for w in snap.items ?? [] {
                realItems.append(ContentItem(title: w.title, platform: w.platform, status: w.status, views: w.views, likes: w.likes, conversion: "真实数据", color: colorMap[w.platform] ?? accent))
            }
        }
        for d in wechatDrafts.prefix(4) {
            realItems.append(ContentItem(title: d.title, platform: "公众号", status: "草稿箱", views: "—", likes: "—", conversion: "\(d.articleCount) 篇", color: .green))
        }
        return realItems.isEmpty ? contents : realItems
    }

    var hasRealData: Bool {
        creatorSnapshots.values.contains(where: \.ok) || !importedMetrics.isEmpty || wechatSummary != nil || douyinSummary != nil || xSummary != nil
    }

    var overviewMetrics: (followers: String, followersDelta: String, posts: String, postsDelta: String, views: String, viewsDelta: String, engagement: String, engagementDelta: String) {
        guard hasRealData else {
            return ("68,972", "↑ 本月 +2,365 · 演示汇总", "110 条", "↑ 比上月多 18 条 · 演示汇总", "286.4 万", "↑ 本月 +31.8% · 演示汇总", "9.8%", "↑ 知识星球表现最好 · 演示汇总")
        }
        var totalFollowers = 0
        var totalDelta = 0
        var totalPosts = 0
        var totalViews = 0
        var totalInteractions = 0
        var connectedCount = 0
        for snap in creatorSnapshots.values where snap.ok {
            connectedCount += 1
            totalFollowers += snap.followers ?? 0
            totalDelta += snap.delta ?? 0
            totalPosts += snap.posts ?? 0
            totalViews += snap.views ?? 0
            totalInteractions += (snap.likes ?? 0) + (snap.comments ?? 0) + (snap.shares ?? 0) + (snap.saves ?? 0)
        }
        for m in importedMetrics.values {
            connectedCount += 1
            totalFollowers += m.followers ?? 0
            totalDelta += m.delta ?? 0
            totalPosts += m.posts ?? 0
            totalViews += m.views ?? 0
            totalInteractions += (m.likes ?? 0) + (m.comments ?? 0) + (m.shares ?? 0) + (m.saves ?? 0)
        }
        if let w = wechatSummary {
            connectedCount += 1
            totalFollowers += w.followers
            totalDelta += w.newFollowers
            totalViews += w.articleReads
            totalInteractions += w.articleShares
        }
        let eng = totalViews > 0 ? String(format: "%.1f%%", Double(totalInteractions) / Double(totalViews) * 100) : "—"
        let viewsStr = totalViews >= 10_000 ? String(format: "%.1f 万", Double(totalViews) / 10_000.0) : format(totalViews)
        return (
            format(totalFollowers),
            "↑ 近期净增 \(totalDelta >= 0 ? "+" : "")\(format(totalDelta)) · 已连 \(connectedCount) 平台",
            "\(format(totalPosts)) 条",
            "已同步真实平台作品 · 真实汇总",
            viewsStr,
            "已接入平台播放/阅读 · 真实汇总",
            eng,
            "互动率（赞评转藏/播放）· 真实汇总"
        )
    }

    let contents: [ContentItem] = [
        .init(title: "AI 也会做梦了？Claude 记忆拆解", platform: "公众号", status: "已发布", views: "6,768", likes: "382", conversion: "9.8%", color: .green),
        .init(title: "我用一个小流程，把 536 个技能管明白了", platform: "小红书", status: "已发布", views: "12,480", likes: "1,106", conversion: "12.4%", color: .red),
        .init(title: "内容创业者最容易忽略的 3 个数据", platform: "视频号", status: "已排期", views: "—", likes: "—", conversion: "待观察", color: .orange)
    ]

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            refreshSavedCSVFiles()
            await refreshSavedConnections()
            lastUpdated = Date()
            refreshing = false
        }
    }

    private func setStatus(forPlatform name: String, _ msg: String) {
        switch name {
        case "抖音": douyinStatus = msg
        case "视频号", "视频号 · 袁六伟": channelsStatus = msg
        case "视频号 · 汇芯袁总": channelsHuixinStatus = msg
        case "视频号 · 山河来电": channelsShanheStatus = msg
        case "小红书": xhsStatus = msg
        case "公众号", "微信公众号": wechatStatus = msg
        default: break
        }
    }

    private func setStatus(forKey key: String, _ msg: String) {
        let map = ["douyin": "抖音", "channels": "视频号 · 袁六伟", "channels_huixin": "视频号 · 汇芯袁总", "channels_shanhe": "视频号 · 山河来电", "xhs": "小红书", "wechat": "公众号"]
        if let name = map[key] { setStatus(forPlatform: name, msg) }
    }

    private func applyCreatorSnapshot(_ snap: CreatorPlatformSnapshot) {
        let name = snap.platform == "视频号" ? "视频号 · 袁六伟" : snap.platform
        if snap.ok {
            creatorSnapshots[name] = snap
            setStatus(forPlatform: name, snap.message ?? "已连接 · \(snap.source ?? name)")
            dataSource = "已接入创作者中心真实数据 · 未连接平台待扫码或导入"
        } else if let msg = snap.message, !msg.isEmpty {
            setStatus(forPlatform: name, msg)
        }
    }

    func syncCreator(key: String) {
        syncingCreatorKey = key
        setStatus(forKey: key, "正在同步…")
        Task {
            if let snap = await bridge.sync(platform: key) {
                applyCreatorSnapshot(snap)
            } else {
                setStatus(forKey: key, "同步脚本调用失败")
            }
            syncingCreatorKey = nil
        }
    }

    func loginCreator(key: String) {
        syncingCreatorKey = key
        setStatus(forKey: key, "请在弹出的窗口中扫码登录…")
        Task {
            if let snap = await bridge.login(platform: key) {
                applyCreatorSnapshot(snap)
            }
            syncingCreatorKey = nil
        }
    }

    private func refreshSavedConnections() async {
        let creatorResults = await bridge.syncAll()
        for (_, snap) in creatorResults {
            applyCreatorSnapshot(snap)
        }
        if let credentials = wechat.savedCredentials() {
            do {
                wechatSummary = try await wechat.fetchSummary(appID: credentials.0, secret: credentials.1)
                wechatStatus = "已连接 · 昨日数据已读取"
            } catch {
                wechatStatus = error.localizedDescription
            }
        }
        if let credentials = x.savedCredentials() {
            do {
                xSummary = try await x.fetchSummary(username: credentials.0, token: credentials.1)
                xStatus = "已连接 · 粉丝 \(format(xSummary?.followers ?? 0))"
            } catch {
                xStatus = error.localizedDescription
            }
        }
        if let credentials = xhs.savedCredentials() {
            do {
                xhsSummary = try await xhs.fetchUser(appID: credentials.0, token: credentials.1)
                xhsStatus = "已连接 · \(xhsSummary?.nickname ?? "已授权账号")（仅基础信息）"
            } catch {
                xhsStatus = error.localizedDescription
            }
        }
        if let credentials = douyin.savedCredentials() {
            do {
                douyinSummary = try await douyin.fetchSummary(openID: credentials.0, token: credentials.1)
                douyinStatus = "已连接 · 粉丝 \(format(douyinSummary?.totalFans ?? 0)) · 近 30 天作品 \(format(douyinSummary?.totalIssue ?? 0)) 条"
            } catch {
                douyinStatus = error.localizedDescription
            }
        }
    }

    func connectWeChat(appID: String, secret: String) {
        wechatStatus = "正在读取昨日数据…"
        Task {
            do {
                let summary = try await wechat.fetchSummary(appID: appID, secret: secret)
                // 只有官方接口验证成功后才保存，避免把空值或错误凭证写入钥匙串。
                wechat.saveCredentials(appID: appID, secret: secret)
                wechatSummary = summary
                wechatStatus = "已连接 · 昨日数据已读取"
                dataSource = "公众号真实数据已连接 · 其他平台仍为演示或手动导入"
            } catch {
                wechatStatus = error.localizedDescription
            }
        }
    }

    func connectX(username: String, token: String) {
        xStatus = "正在读取 X 账号…"
        Task {
            do {
                let summary = try await x.fetchSummary(username: username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: ""), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                x.saveCredentials(username: username, token: token)
                xSummary = summary
                xStatus = "已连接 · 粉丝 \(format(summary.followers))"
                dataSource = "X 官方数据已连接 · 其他平台仍为演示或手动导入"
            } catch {
                xStatus = error.localizedDescription
            }
        }
    }

    func connectXHS(appID: String, token: String) {
        xhsStatus = "正在验证小红书官方授权…"
        Task {
            do {
                let profile = try await xhs.fetchUser(appID: appID.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                xhs.saveCredentials(appID: appID, token: token)
                xhsSummary = profile
                xhsStatus = "已连接 · \(profile.nickname)（仅基础信息）"
                dataSource = "小红书官方账号已连接 · 统计数据仍需平台开放权限"
            } catch {
                xhsStatus = error.localizedDescription
            }
        }
    }

    func connectDouyin(openID: String, token: String) {
        douyinStatus = "正在读取抖音官方数据…"
        Task {
            do {
                let summary = try await douyin.fetchSummary(openID: openID.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                douyin.saveCredentials(openID: openID, token: token)
                douyinSummary = summary
                douyinStatus = "已连接 · 粉丝 \(format(summary.totalFans)) · 近 30 天作品 \(format(summary.totalIssue)) 条"
                dataSource = "抖音官方数据已连接 · 其他平台仍为演示或手动导入"
            } catch {
                douyinStatus = error.localizedDescription
            }
        }
    }

    func loadWeChatDrafts() {
        guard let credentials = wechat.savedCredentials() else {
            wechatDraftStatus = "请先连接公众号"
            return
        }
        wechatDraftStatus = "正在读取官方草稿箱…"
        Task {
            do {
                let drafts = try await wechat.fetchDrafts(appID: credentials.0, secret: credentials.1)
                wechatDrafts = drafts
                wechatDraftStatus = "官方草稿箱 · \(drafts.count) 条"
            } catch {
                wechatDraftStatus = error.localizedDescription
            }
        }
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "汇芯内容创业管家-平台报告.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func csv(_ value: String) -> String {
            let quote = String(UnicodeScalar(34))
            let escaped = value.replacingOccurrences(of: quote, with: quote + quote)
            return quote + escaped + quote
        }
        var lines = ["平台,粉丝,净增,本月内容,互动率,数据来源,更新时间"]
        let updatedAt = lastUpdated.formatted(date: .numeric, time: .shortened)
        lines.append(contentsOf: displayPlatforms.map { item in
            [item.name, item.followers, item.delta, item.posts, item.engagement, item.source, updatedAt].map(csv).joined(separator: ",")
        })
        let output = "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            dataSource = "报告导出失败：\(error.localizedDescription)"
        }
    }

    func importCSV(for platform: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importedCSVPaths[platform] = url.path
        UserDefaults.standard.set(importedCSVPaths, forKey: importedCSVPathsKey)
        loadCSV(at: url, for: platform)
        dataSource = "CSV 已记住 · 文件变化后每分钟自动更新"
    }

    private func refreshSavedCSVFiles(force: Bool = false) {
        for (platform, path) in importedCSVPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if force || importedCSVModifiedDates[platform] != modified {
                loadCSV(at: url, for: platform, modified: modified)
            }
        }
    }

    private func loadCSV(at url: URL, for platform: String, modified: Date? = nil) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let headerLine = lines.first else { importedCounts[platform] = 0; return }
            let headers = parseCSVLine(headerLine).map(normalize)
            let rows = lines.dropFirst().map(parseCSVLine).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
            importedCounts[platform] = rows.count
            importedMetrics[platform] = metrics(headers: headers, rows: rows)
            importedCSVModifiedDates[platform] = modified ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date())
            saveImportedData()
            dataSource = "CSV 已记住 · 文件变化后每分钟自动更新"
        } catch {
            dataSource = "CSV 读取失败：\(error.localizedDescription)"
        }
    }

    private func metrics(headers: [String], rows: [[String]]) -> ImportedPlatformMetrics {
        func value(_ aliases: [String]) -> Int? {
            guard let index = headers.firstIndex(where: { aliases.contains($0) }) else { return nil }
            return rows.compactMap { row in
                guard index < row.count else { return nil }
                let cleaned = row[index].replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                return Int(cleaned)
            }.last
        }
        return ImportedPlatformMetrics(
            followers: value(["followers", "follower", "粉丝", "粉丝数", "followercount", "fans"]),
            delta: value(["delta", "净增", "涨粉", "新增粉丝", "newfollowers"]),
            posts: value(["posts", "发布量", "发布", "作品数", "内容数"]),
            views: value(["views", "播放", "播放量", "阅读", "阅读量", "reads"]),
            likes: value(["likes", "点赞", "点赞数"]),
            comments: value(["comments", "评论", "评论数"]),
            shares: value(["shares", "分享", "分享数", "转发", "转发数"]),
            saves: value(["saves", "收藏", "收藏数"])
        )
    }

    private func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FEFF}", with: "").lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { quoted.toggle() }
            else if character == "," && !quoted { result.append(field); field = "" }
            else { field.append(character) }
        }
        result.append(field)
        return result
    }

    private func saveImportedData() {
        let snapshots = importedMetrics.reduce(into: [String: ImportedPlatformSnapshot]()) { result, entry in
            result[entry.key] = ImportedPlatformSnapshot(count: importedCounts[entry.key] ?? 0, metrics: entry.value)
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: importedDataKey)
        }
    }

    private func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

let accent = Color(red: 0.76, green: 0.08, blue: 0.18)

struct MetricCard: View {
    let title: String
    let value: String
    let delta: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(accent)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
            Text(delta).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.05)))
    }
}

struct PlatformCard: View {
    let item: Platform
    private var parts: (title: String, badge: String?) {
        let comps = item.name.components(separatedBy: " · ")
        if comps.count >= 2 { return (comps[0], comps[1]) }
        return (item.name, nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 18)
                Text(parts.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let badge = parts.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(item.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(item.color.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.delta)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.delta == "—" ? Color.secondary : Color.green)
                    .lineLimit(1)
            }
            Text(item.followers).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
            HStack {
                Text("粉丝").foregroundStyle(.secondary)
                Spacer()
                Text("内容 " + item.posts + " 条").foregroundStyle(.secondary)
            }.font(.system(size: 10))
            HStack {
                Text("互动率")
                Spacer()
                Text(item.engagement).fontWeight(.semibold)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(item.source)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(item.source == "待连接" ? Color.secondary : (item.source == "演示数据" ? Color.orange : Color.green))
                .lineLimit(1)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TrendChart: View {
    let values = [0.25, 0.31, 0.28, 0.43, 0.46, 0.55, 0.51, 0.72, 0.66, 0.82, 0.91, 0.86]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("近 30 天增长趋势").font(.system(size: 14, weight: .semibold)); Spacer(); Text("粉丝净增 +2,365").font(.system(size: 11)).foregroundStyle(.green) }
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [accent, accent.opacity(0.18)], startPoint: .top, endPoint: .bottom)).frame(maxWidth: .infinity).frame(height: CGFloat(value) * 130)
                }
            }.frame(height: 140, alignment: .bottom)
            HStack { Text("10-15"); Spacer(); Text("10-22"); Spacer(); Text("10-29"); Spacer(); Text("11-05"); Spacer(); Text("11-12") }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ContentRow: View {
    let item: ContentItem
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(item.color.opacity(0.12)).frame(width: 34, height: 34).overlay(Image(systemName: "doc.text.fill").foregroundStyle(item.color))
            VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1); Text("\(item.platform) · \(item.status)").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) { Text(item.views).font(.system(size: 12, weight: .semibold)).monospacedDigit(); Text("播放").font(.system(size: 9)).foregroundStyle(.tertiary) }
            VStack(alignment: .trailing, spacing: 3) { Text(item.conversion).font(.system(size: 12, weight: .semibold)).monospacedDigit(); Text("转化").font(.system(size: 9)).foregroundStyle(.tertiary) }
        }.padding(.vertical, 9)
    }
}

struct Dashboard: View {
    @ObservedObject var store: ContentStore
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    @State private var about = false
    @State private var wechatSheet = false
    @State private var xSheet = false
    @State private var xhsSheet = false
    @State private var douyinSheet = false
    @State private var connectionSheet = false
    @State private var vaultSheet = false
    @State private var vaultPhone = ""
    @State private var vaultEmail = ""
    @State private var vaultCompany = ""
    @State private var vaultContact = ""
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var xUsername = ""
    @State private var xToken = ""
    @State private var xhsAppID = ""
    @State private var xhsToken = ""
    @State private var douyinOpenID = ""
    @State private var douyinToken = ""
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 11) {
                Text("汇芯").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).padding(9).background(accent, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) { Text("内容管家").font(.system(size: 21, weight: .bold)); Text("多平台创作者数据直连 · 袁六伟 · 台州汇芯").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button { store.refresh() } label: { Label(store.refreshing ? "更新中" : "更新", systemImage: "arrow.clockwise") }.controlSize(.small).disabled(store.refreshing)
                Button("信息保险库") { let profile = store.savedProfile(); vaultPhone = profile.phone; vaultEmail = profile.email; vaultCompany = profile.company; vaultContact = profile.contact; vaultSheet = true }.controlSize(.small)
                Button("连接平台") { connectionSheet = true }.controlSize(.small)
                Menu { Button("导出平台报告") { store.exportReport() }; Button("使用说明") { about = true }; Button("打开独立窗口") { (NSApp.delegate as? AppDelegate)?.showWindow() }; Divider(); Button("退出汇芯内容管家") { NSApp.terminate(nil) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            Picker("", selection: $store.selectedTab) { ForEach(store.tabs, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            ScrollView {
                if store.selectedTab == "总览" { overview }
                else if store.selectedTab == "内容" { contentView }
                else if store.selectedTab == "平台" { platformView }
                else { reviewView }
            }
            HStack { Text(store.dataSource).font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Text("更新于 \(store.lastUpdated.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(20).frame(width: 900, height: 650).background(Color(nsColor: .windowBackgroundColor)).sheet(isPresented: $about) { Text("汇芯内容管家\n支持抖音、视频号、小红书创作者中心直连，以及公众号草稿箱和 CSV 导入。\n\n袁六伟 · 台州汇芯").font(.system(size: 13)).multilineTextAlignment(.leading).padding(28).frame(width: 430) }.sheet(isPresented: $vaultSheet) { vaultForm }.sheet(isPresented: $wechatSheet) { wechatForm }.sheet(isPresented: $xSheet) { xForm }.sheet(isPresented: $xhsSheet) { xhsForm }.sheet(isPresented: $douyinSheet) { douyinForm }.sheet(isPresented: $connectionSheet) { connectionForm }
    }
    var vaultForm: some View { VStack(alignment: .leading, spacing: 14) { Text("信息保险库").font(.title2.bold()); Text("常用资料只保存在本机 macOS 钥匙串，方便后续填写平台申请表。不会自动上传证件，也不会写入 GitHub。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("手机号", text: $vaultPhone).textFieldStyle(.roundedBorder); TextField("联系邮箱", text: $vaultEmail).textFieldStyle(.roundedBorder); TextField("公司主体全称", text: $vaultCompany).textFieldStyle(.roundedBorder); TextField("联系人姓名", text: $vaultContact).textFieldStyle(.roundedBorder); Text("状态：\(store.vaultStatus)").font(.system(size: 11)).foregroundStyle(.secondary); HStack { Spacer(); Button("取消") { vaultSheet = false }; Button("保存到本机") { store.saveProfile(phone: vaultPhone, email: vaultEmail, company: vaultCompany, contact: vaultContact); vaultSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 540) }
    private func creatorKey(for name: String) -> String? {
        switch name {
        case "微信公众号": return "wechat"
        case "抖音": return "douyin"
        case "视频号 · 袁六伟": return "channels"
        case "视频号 · 汇芯袁总": return "channels_huixin"
        case "视频号 · 山河来电": return "channels_shanhe"
        case "小红书": return "xhs"
        default: return nil
        }
    }

    private func statusText(for name: String, fallback: String) -> String {
        switch name {
        case "微信公众号": return store.wechatStatus
        case "X / Twitter": return store.xStatus
        case "小红书": return store.xhsStatus
        case "抖音": return store.douyinStatus
        case "视频号 · 袁六伟": return store.channelsStatus
        case "视频号 · 汇芯袁总": return store.channelsHuixinStatus
        case "视频号 · 山河来电": return store.channelsShanheStatus
        default: return fallback
        }
    }

    var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("平台连接中心").font(.title2.bold())
            Text("支持公众号、抖音、小红书及 3 个视频号（袁六伟 / 汇芯袁总 / 山河来电）扫码直连，无需企业开放平台审核。").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(store.connections) { item in
                let st = statusText(for: item.name, fallback: item.state)
                let cKey = creatorKey(for: item.name)
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 12, weight: .semibold))
                        Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        if store.importedCounts[item.name] != nil {
                            Text(store.importedCSVPaths[item.name] != nil ? "CSV 自动同步" : "已导入记录").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                        }
                    }
                    Spacer()
                    Text(st)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(st.hasPrefix("已连接") ? .green : (st.contains("扫码") ? .orange : .secondary))
                        .lineLimit(1)
                    if let cKey {
                        Button("扫码登录") { store.loginCreator(key: cKey) }
                            .controlSize(.small)
                            .disabled(store.syncingCreatorKey == cKey)
                        Button(store.syncingCreatorKey == cKey ? "同步中" : "同步") { store.syncCreator(key: cKey) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .disabled(store.syncingCreatorKey == cKey)
                    }
                    if item.name == "微信公众号" {
                        Button("设置") { connectionSheet = false; wechatSheet = true }.controlSize(.small)
                    } else if item.name == "X / Twitter" {
                        Button("设置") { connectionSheet = false; xSheet = true }.controlSize(.small)
                    } else if item.name == "小红书" {
                        Button("OpenAPI") { connectionSheet = false; xhsSheet = true }.controlSize(.small)
                    } else if item.name == "抖音" {
                        Button("OpenAPI") { connectionSheet = false; douyinSheet = true }.controlSize(.small)
                    }
                    if item.name != "微信公众号" {
                        Button("CSV") { store.importCSV(for: item.name) }.controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack { Spacer(); Button("完成") { connectionSheet = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 820)
    }
    var wechatForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接微信公众号").font(.title2.bold()); Text("读取昨日粉丝和图文数据。AppID、AppSecret 只保存在本机钥匙串，不会写入 GitHub 或上传到第三方。公众号后台还需要配置服务器出口 IP 白名单。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("公众号 AppID", text: $appID).textFieldStyle(.roundedBorder); SecureField("公众号 AppSecret", text: $appSecret).textFieldStyle(.roundedBorder); Text(store.wechatStatus).font(.system(size: 11)).foregroundStyle(store.wechatStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { wechatSheet = false }; Button("连接并读取") { store.connectWeChat(appID: appID, secret: appSecret); wechatSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 500) }
    var xForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接 X / Twitter").font(.title2.bold()); Text("使用 X Developer 的用户 Bearer Token 读取公开账号信息。Token 只保存在本机钥匙串，不会写入 GitHub。没有 Token 时可先点击平台连接中心的“官方入口”。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("X 用户名（不含 @）", text: $xUsername).textFieldStyle(.roundedBorder); SecureField("User Bearer Token", text: $xToken).textFieldStyle(.roundedBorder); Text(store.xStatus).font(.system(size: 11)).foregroundStyle(store.xStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { xSheet = false }; Button("连接并读取") { store.connectX(username: xUsername, token: xToken); xSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 540) }
    var xhsForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接小红书开放平台").font(.title2.bold()); Text("当前官方仅开放 basic_info。输入应用 App ID 和 OAuth Access Token 后，应用会验证小红书授权账号的基础身份；粉丝数、笔记数等统计权限尚未开放。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("小红书 App ID", text: $xhsAppID).textFieldStyle(.roundedBorder); SecureField("OAuth Access Token", text: $xhsToken).textFieldStyle(.roundedBorder); Text(store.xhsStatus).font(.system(size: 11)).foregroundStyle(store.xhsStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { xhsSheet = false }; Button("验证并连接") { store.connectXHS(appID: xhsAppID, token: xhsToken); xhsSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 600) }
    var douyinForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接抖音开放平台").font(.title2.bold()); Text("使用抖音 OAuth 授权后得到的 open_id 和 access_token，读取近 30 天官方作品数量与新增播放。Token 只保存在本机钥匙串。首次授权后的统计数据可能需要等待官方生成。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("抖音 open_id", text: $douyinOpenID).textFieldStyle(.roundedBorder); SecureField("OAuth Access Token", text: $douyinToken).textFieldStyle(.roundedBorder); Text(store.douyinStatus).font(.system(size: 11)).foregroundStyle(store.douyinStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { douyinSheet = false }; Button("验证并读取") { store.connectDouyin(openID: douyinOpenID, token: douyinToken); douyinSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 600) }
    var overview: some View {
        let m = store.overviewMetrics
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                MetricCard(title: "全平台粉丝", value: m.followers, delta: m.followersDelta, symbol: "person.3.fill")
                MetricCard(title: "近期发布", value: m.posts, delta: m.postsDelta, symbol: "paperplane.fill")
                MetricCard(title: "总播放 / 阅读", value: m.views, delta: m.viewsDelta, symbol: "play.circle.fill")
                MetricCard(title: "内容互动率", value: m.engagement, delta: m.engagementDelta, symbol: "arrow.up.right")
            }
            HStack(alignment: .top, spacing: 14) {
                TrendChart().frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Text("今天值得关注").font(.system(size: 14, weight: .semibold))
                    if let dy = store.creatorSnapshots["抖音"], dy.ok {
                        insight("抖音创作者中心已直连", "粉丝 \(dy.followers ?? 0) · 播放 \(dy.views ?? 0)", .black)
                    } else {
                        insight("小红书近 7 天涨粉最多", "+666 粉丝，占整体增长 28% · 演示", .red)
                    }
                    if let ch = store.creatorSnapshots["视频号 · 袁六伟"], ch.ok {
                        insight("视频号 · 袁六伟已直连", "关注者 \(ch.followers ?? 0) · 视频 \(ch.posts ?? 0) 条", .orange)
                    } else {
                        insight("视频号支持 3 账号扫码直连", "点击右上角「连接平台」扫码同步袁六伟/汇芯袁总/山河来电", .orange)
                    }
                    if let summary = store.wechatSummary {
                        insight("公众号昨日数据已接入", "净增 \(summary.newFollowers)，阅读 \(summary.articleReads)", .green)
                    } else {
                        insight("公众号内容可以复用", "连接后这里会显示真实昨日数据", .green)
                    }
                }.padding(16).frame(width: 270, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("平台表现").font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(store.displayPlatforms) { PlatformCard(item: $0) }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近内容").font(.system(size: 14, weight: .semibold))
                    ForEach(store.displayContents.prefix(4)) { ContentRow(item: $0) }
                }.padding(16).frame(width: 390, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(.top, 1)
    }
    func insight(_ title: String, _ detail: String, _ color: Color) -> some View { HStack(alignment: .top, spacing: 8) { Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) } } }
    var contentView: some View { VStack(alignment: .leading, spacing: 12) { HStack { VStack(alignment: .leading, spacing: 4) { Text("内容库").font(.system(size: 17, weight: .bold)); Text("自动聚合创作者中心近期作品与公众号官方草稿箱。").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Button { store.loadWeChatDrafts() } label: { Label("刷新公众号草稿", systemImage: "arrow.clockwise") }.controlSize(.small) }; HStack { Text(store.wechatDraftStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(store.wechatDraftStatus.contains("官方") ? .green : .secondary); Spacer() }.padding(.bottom, 2); if !store.wechatDrafts.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("公众号草稿箱").font(.system(size: 13, weight: .semibold)); ForEach(store.wechatDrafts) { draft in HStack { Image(systemName: "doc.text").foregroundStyle(.green); VStack(alignment: .leading, spacing: 3) { Text(draft.title).font(.system(size: 12, weight: .medium)); Text("\(draft.articleCount) 篇图文 · \(draft.updateTime.map { Self.dateFormatter.string(from: $0) } ?? "时间未知")").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Text("草稿").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange) }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)) } }.padding(.bottom, 6) }; ForEach(store.displayContents) { ContentRow(item: $0).padding(.horizontal, 12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) } }.padding(.top, 10) }
    var platformView: some View { VStack(alignment: .leading, spacing: 10) { Text("平台总览").font(.system(size: 17, weight: .bold)); Text(store.dataSource).font(.system(size: 11)).foregroundStyle(.secondary); LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { ForEach(store.displayPlatforms) { PlatformCard(item: $0) } } }.padding(.top, 10) }
    var reviewView: some View { VStack(alignment: .leading, spacing: 14) { Text("内容复盘").font(.system(size: 17, weight: .bold)); Text("系统会根据真实数据自动生成：哪些主题值得继续、哪些内容适合改编、哪个平台正在增长。").font(.system(size: 12)).foregroundStyle(.secondary); TrendChart(); Text("下一步建议").font(.system(size: 14, weight: .semibold)); insight("把“技能管家”案例拆成 3 个短内容", "已有内容表现好，适合跨平台二次分发", accent); insight("给小红书增加案例型标题", "近 7 天互动率明显高于其他平台", .red); insight("建立咨询转化记录", "目前只能看到播放和互动，成交数据还没有接入", .orange) }.padding(.top, 10) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ContentStore()
    var status: NSStatusItem!
    var popover: NSPopover!
    var window: NSWindow?
    var relayProcess: Process?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startWeChatRelayTunnel()
        popover = NSPopover(); popover.contentViewController = NSHostingController(rootView: Dashboard(store: store)); popover.contentSize = NSSize(width: 900, height: 650); popover.behavior = .transient
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button { button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "汇芯内容管家"); button.image?.isTemplate = true; button.toolTip = "汇芯内容管家"; button.target = self; button.action = #selector(toggle) }
        if CommandLine.arguments.contains("--show") { showWindow() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        relayProcess?.terminate()
    }
    private func startWeChatRelayTunnel() {
        let key = "/Users/yuanliuwei/.ssh/opencław_wechat_publish"
        guard FileManager.default.fileExists(atPath: key) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ExitOnForwardFailure=yes", "-i", key, "-L", "18848:127.0.0.1:3002", "root@43.156.246.8"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try? process.run()
        relayProcess = process
    }
    @objc func toggle() { if popover.isShown { popover.performClose(nil) } else { guard let button = status.button else { return }; NSApp.activate(ignoringOtherApps: true); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) } }
    func showWindow() { let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false); w.title = "汇芯内容管家"; w.contentView = NSHostingView(rootView: Dashboard(store: store)); w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window = w }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

