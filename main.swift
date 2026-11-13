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
    @Published var biliSummary: BiliSummary?
    @Published var biliStatus = "尚未连接"
    @Published var xhsSummary: XHSSummary?
    @Published var xhsStatus = "尚未连接"
    @Published var wechatStatus = "尚未连接"
    @Published var importedCounts: [String: Int] = [:]
    @Published var importedMetrics: [String: ImportedPlatformMetrics] = [:]
    @Published var dataSource = "演示数据 · 尚未连接平台"
    private let wechat = WeChatConnector()
    private let x = XConnector()
    private let bili = BiliConnector()
    private let xhs = XHSConnector()
    private let importedDataKey = "cn.huixin.contentmanager.imported-platform-data"

    init() {
        guard let data = UserDefaults.standard.data(forKey: importedDataKey),
              let snapshots = try? JSONDecoder().decode([String: ImportedPlatformSnapshot].self, from: data) else { return }
        importedCounts = snapshots.mapValues(\.count)
        importedMetrics = snapshots.mapValues(\.metrics)
        if !snapshots.isEmpty { dataSource = "包含已保存的手动导入数据 · 未连接平台不显示为真实数据" }
    }

    let tabs = ["总览", "内容", "平台", "复盘"]
    let connections: [PlatformConnection] = [
        .init(name: "微信公众号", symbol: "bubble.left.and.bubble.right.fill", state: "已具备接口", detail: "需要 AppID、AppSecret 和 IP 白名单", color: .green, docsURL: "https://developers.weixin.qq.com/doc/offiaccount/Basic_Information/Get_access_token.html"),
        .init(name: "抖音", symbol: "music.note", state: "待配置应用", detail: "官方 OAuth + 视频数据权限，需开放平台审核", color: .black, docsURL: "https://open.douyin.com/"),
        .init(name: "B站", symbol: "tv.fill", state: "待核实权限", detail: "先保留官方开放平台入口和 CSV 导入", color: .blue, docsURL: "https://openhome.bilibili.com/"),
        .init(name: "X / Twitter", symbol: "at", state: "待配置应用", detail: "需要 X Developer 应用和 OAuth 用户授权", color: .primary, docsURL: "https://developer.x.com/"),
        .init(name: "小红书", symbol: "note.text", state: "待配置应用", detail: "官方开放能力依赖主体与应用审核", color: .red, docsURL: "https://open.xiaohongshu.com/"),
        .init(name: "视频号", symbol: "play.rectangle.fill", state: "暂用导入", detail: "先保留手动导入，避免绕过平台限制", color: .orange, docsURL: nil)
    ]
    let platforms: [Platform] = [
        .init(name: "公众号", symbol: "bubble.left.and.bubble.right.fill", color: .green, followers: "12,680", delta: "+386", posts: "18", engagement: "8.6%"),
        .init(name: "小红书", symbol: "note.text", color: .red, followers: "19,122", delta: "+666", posts: "24", engagement: "15.9%"),
        .init(name: "视频号", symbol: "play.rectangle.fill", color: .orange, followers: "4,584", delta: "+189", posts: "12", engagement: "6.8%"),
        .init(name: "抖音", symbol: "music.note", color: .black, followers: "13,060", delta: "+344", posts: "16", engagement: "9.2%"),
        .init(name: "B站", symbol: "tv.fill", color: .blue, followers: "15,972", delta: "+344", posts: "9", engagement: "11.4%"),
        .init(name: "X", symbol: "at", color: .primary, followers: "—", delta: "—", posts: "—", engagement: "—"),
        .init(name: "知识星球", symbol: "person.3.fill", color: .purple, followers: "3,554", delta: "+1,022", posts: "31", engagement: "18.2%")
    ]

    var displayPlatforms: [Platform] {
        platforms.map { item in
            if let imported = importedMetrics[item.name] {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: imported.followers.map(format) ?? "—",
                                delta: imported.delta.map { $0 >= 0 ? "+\(format($0))" : format($0) } ?? "—",
                                posts: imported.posts.map(format) ?? "—",
                                engagement: imported.engagement)
            }
            if item.name == "X", let summary = xSummary {
                return Platform(name: item.name, symbol: item.symbol, color: item.color,
                                followers: format(summary.followers), delta: "—",
                                posts: format(summary.posts), engagement: "—")
            }
            guard item.name == "公众号", let summary = wechatSummary else { return item }
            return Platform(name: item.name, symbol: item.symbol, color: item.color,
                            followers: format(summary.followers),
                            delta: summary.newFollowers >= 0 ? "+\(format(summary.newFollowers))" : format(summary.newFollowers),
                            posts: item.posts, engagement: item.engagement)
        }
    }

    let contents: [ContentItem] = [
        .init(title: "AI 也会做梦了？Claude 记忆拆解", platform: "公众号", status: "已发布", views: "6,768", likes: "382", conversion: "9.8%", color: .green),
        .init(title: "我用一个小流程，把 536 个技能管明白了", platform: "小红书", status: "已发布", views: "12,480", likes: "1,106", conversion: "12.4%", color: .red),
        .init(title: "内容创业者最容易忽略的 3 个数据", platform: "视频号", status: "已排期", views: "—", likes: "—", conversion: "待观察", color: .orange),
        .init(title: "Token 不够用？先看这张额度地图", platform: "B站", status: "已发布", views: "3,226", likes: "511", conversion: "6.2%", color: .blue)
    ]

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.lastUpdated = Date()
            self.refreshing = false
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
                xStatus = "已连接 · 粉丝 (format(summary.followers))"
                dataSource = "X 官方数据已连接 · 其他平台仍为演示或手动导入"
            } catch {
                xStatus = error.localizedDescription
            }
        }
    }

    func connectBili(accessKey: String, secret: String, token: String) {
        biliStatus = "正在验证 B 站官方授权…"
        Task {
            do {
                let profile = try await bili.fetchProfile(accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                bili.saveCredentials(accessKey: accessKey, secret: secret, token: token)
                biliSummary = profile
                biliStatus = "已连接 · (profile.name)"
                dataSource = "B 站官方账号已连接 · 其他平台仍为演示或手动导入"
            } catch {
                biliStatus = error.localizedDescription
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
                xhsStatus = "已连接 · (profile.nickname)（仅基础信息）"
                dataSource = "小红书官方账号已连接 · 统计数据仍需平台开放权限"
            } catch {
                xhsStatus = error.localizedDescription
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
                wechatDraftStatus = "官方草稿箱 · (drafts.count) 条"
            } catch {
                wechatDraftStatus = error.localizedDescription
            }
        }
    }

    func importCSV(for platform: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let headerLine = lines.first else { importedCounts[platform] = 0; return }
            let headers = parseCSVLine(headerLine).map(normalize)
            let rows = lines.dropFirst().map(parseCSVLine).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
            importedCounts[platform] = rows.count
            importedMetrics[platform] = metrics(headers: headers, rows: rows)
            saveImportedData()
            dataSource = "包含手动导入数据 · 未连接平台不显示为真实数据"
        } catch {
            importedCounts[platform] = 0
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 21)
                Text(item.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(item.delta).font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
            }
            Text(item.followers).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
            HStack {
                Text("粉丝").foregroundStyle(.secondary)
                Spacer()
                Text("本月内容 " + item.posts + " 条").foregroundStyle(.secondary)
            }.font(.system(size: 10))
            HStack {
                Text("互动率")
                Spacer()
                Text(item.engagement).fontWeight(.semibold)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var biliSheet = false
    @State private var xhsSheet = false
    @State private var connectionSheet = false
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var xUsername = ""
    @State private var xToken = ""
    @State private var biliAccessKey = ""
    @State private var biliSecret = ""
    @State private var biliToken = ""
    @State private var xhsAppID = ""
    @State private var xhsToken = ""
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 11) {
                Text("汇芯").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).padding(9).background(accent, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) { Text("内容创业管家").font(.system(size: 21, weight: .bold)); Text("看清内容表现，知道下一步做什么").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button { store.refresh() } label: { Label(store.refreshing ? "更新中" : "更新", systemImage: "arrow.clockwise") }.controlSize(.small).disabled(store.refreshing)
                Button("连接平台") { connectionSheet = true }.controlSize(.small)
                Menu { Button("使用说明") { about = true }; Button("打开独立窗口") { (NSApp.delegate as? AppDelegate)?.showWindow() }; Divider(); Button("退出汇芯 内容创业管家") { NSApp.terminate(nil) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            Picker("", selection: $store.selectedTab) { ForEach(store.tabs, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            ScrollView {
                if store.selectedTab == "总览" { overview }
                else if store.selectedTab == "内容" { contentView }
                else if store.selectedTab == "平台" { platformView }
                else { reviewView }
            }
            HStack { Text(store.dataSource).font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Text("更新于 \(store.lastUpdated.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(20).frame(width: 900, height: 650).background(Color(nsColor: .windowBackgroundColor)).sheet(isPresented: $about) { Text("汇芯内容创业管家\n官方优先接入公众号草稿箱和可用数据；其他平台支持授权或 CSV 导入。\n\n袁六伟 · 台州汇芯").font(.system(size: 13)).multilineTextAlignment(.leading).padding(28).frame(width: 430) }.sheet(isPresented: $wechatSheet) { wechatForm }.sheet(isPresented: $xSheet) { xForm }.sheet(isPresented: $biliSheet) { biliForm }.sheet(isPresented: $xhsSheet) { xhsForm }.sheet(isPresented: $connectionSheet) { connectionForm }
    }
    var connectionForm: some View { VStack(alignment: .leading, spacing: 14) { Text("平台连接中心").font(.title2.bold()); Text("每个平台单独授权，数据来源和权限状态清楚可见。公众号走官方接口，其余平台可先查看官方入口或导入后台导出的 CSV。").font(.system(size: 12)).foregroundStyle(.secondary); ForEach(store.connections) { item in HStack(spacing: 12) { Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 24); VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.system(size: 12, weight: .semibold)); Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary); if let count = store.importedCounts[item.name] { Text("已导入 (count) 条记录").font(.system(size: 10, weight: .medium)).foregroundStyle(.green) } }; Spacer(); Text(item.name == "微信公众号" ? store.wechatStatus : item.name == "X / Twitter" ? store.xStatus : item.name == "B站" ? store.biliStatus : item.name == "小红书" ? store.xhsStatus : item.state).font(.system(size: 10, weight: .medium)).foregroundStyle((item.name == "微信公众号" && store.wechatStatus.hasPrefix("已连接")) || (item.name == "X / Twitter" && store.xStatus.hasPrefix("已连接")) || (item.name == "B站" && store.biliStatus.hasPrefix("已连接")) || (item.name == "小红书" && store.xhsStatus.hasPrefix("已连接")) ? .green : .secondary); if item.name == "微信公众号" { Button("设置") { connectionSheet = false; wechatSheet = true } } else if item.name == "X / Twitter" { Button("设置") { connectionSheet = false; xSheet = true }; if let url = item.docsURL { Button("官方入口") { NSWorkspace.shared.open(URL(string: url)!) } }; Button("导入 CSV") { store.importCSV(for: item.name) } } else if item.name == "B站" { Button("设置") { connectionSheet = false; biliSheet = true }; if let url = item.docsURL { Button("官方入口") { NSWorkspace.shared.open(URL(string: url)!) } }; Button("导入 CSV") { store.importCSV(for: item.name) } } else if item.name == "小红书" { Button("设置") { connectionSheet = false; xhsSheet = true }; if let url = item.docsURL { Button("官方入口") { NSWorkspace.shared.open(URL(string: url)!) } }; Button("导入 CSV") { store.importCSV(for: item.name) } } else { if let url = item.docsURL { Button("官方入口") { NSWorkspace.shared.open(URL(string: url)!) } }; Button("导入 CSV") { store.importCSV(for: item.name) } } }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)) }; HStack { Spacer(); Button("完成") { connectionSheet = false }.keyboardShortcut(.defaultAction) } }.padding(24).frame(width: 740) }
    var wechatForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接微信公众号").font(.title2.bold()); Text("读取昨日粉丝和图文数据。AppID、AppSecret 只保存在本机钥匙串，不会写入 GitHub 或上传到第三方。公众号后台还需要配置服务器出口 IP 白名单。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("公众号 AppID", text: $appID).textFieldStyle(.roundedBorder); SecureField("公众号 AppSecret", text: $appSecret).textFieldStyle(.roundedBorder); Text(store.wechatStatus).font(.system(size: 11)).foregroundStyle(store.wechatStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { wechatSheet = false }; Button("连接并读取") { store.connectWeChat(appID: appID, secret: appSecret); wechatSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 500) }
    var xForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接 X / Twitter").font(.title2.bold()); Text("使用 X Developer 的用户 Bearer Token 读取公开账号信息。Token 只保存在本机钥匙串，不会写入 GitHub。没有 Token 时可先点击平台连接中心的“官方入口”。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("X 用户名（不含 @）", text: $xUsername).textFieldStyle(.roundedBorder); SecureField("User Bearer Token", text: $xToken).textFieldStyle(.roundedBorder); Text(store.xStatus).font(.system(size: 11)).foregroundStyle(store.xStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { xSheet = false }; Button("连接并读取") { store.connectX(username: xUsername, token: xToken); xSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 540) }
    var biliForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接 B 站开放平台").font(.title2.bold()); Text("使用 B 站开放平台应用的 Access Key、App Secret 和 OAuth Access Token，按官方 HMAC-SHA256 签名验证账号。凭证只保存在本机钥匙串。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("Access Key / client_id", text: $biliAccessKey).textFieldStyle(.roundedBorder); SecureField("App Secret", text: $biliSecret).textFieldStyle(.roundedBorder); SecureField("OAuth Access Token", text: $biliToken).textFieldStyle(.roundedBorder); Text(store.biliStatus).font(.system(size: 11)).foregroundStyle(store.biliStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { biliSheet = false }; Button("验证并连接") { store.connectBili(accessKey: biliAccessKey, secret: biliSecret, token: biliToken); biliSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 580) }
    var xhsForm: some View { VStack(alignment: .leading, spacing: 16) { Text("连接小红书开放平台").font(.title2.bold()); Text("当前官方仅开放 basic_info。输入应用 App ID 和 OAuth Access Token 后，应用会验证小红书授权账号的基础身份；粉丝数、笔记数等统计权限尚未开放。").font(.system(size: 12)).foregroundStyle(.secondary); TextField("小红书 App ID", text: $xhsAppID).textFieldStyle(.roundedBorder); SecureField("OAuth Access Token", text: $xhsToken).textFieldStyle(.roundedBorder); Text(store.xhsStatus).font(.system(size: 11)).foregroundStyle(store.xhsStatus.hasPrefix("已连接") ? .green : .secondary); HStack { Spacer(); Button("取消") { xhsSheet = false }; Button("验证并连接") { store.connectXHS(appID: xhsAppID, token: xhsToken); xhsSheet = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 600) }
    var overview: some View { VStack(spacing: 14) { HStack(spacing: 12) { MetricCard(title: "全平台粉丝", value: "68,972", delta: "↑ 本月 +2,365 · 演示汇总", symbol: "person.3.fill"); MetricCard(title: "本月发布", value: "110 条", delta: "↑ 比上月多 18 条 · 演示汇总", symbol: "paperplane.fill"); MetricCard(title: "总播放 / 阅读", value: "286.4 万", delta: "↑ 本月 +31.8% · 演示汇总", symbol: "play.circle.fill"); MetricCard(title: "内容转化", value: "9.8%", delta: "↑ 知识星球表现最好 · 演示汇总", symbol: "arrow.up.right") }; HStack(alignment: .top, spacing: 14) { TrendChart().frame(maxWidth: .infinity); VStack(alignment: .leading, spacing: 12) { Text("今天值得关注").font(.system(size: 14, weight: .semibold)); insight("小红书近 7 天涨粉最多", "+666 粉丝，占整体增长 28% · 演示", .red); insight("知识星球转化最高", "注册转化率 18.2% · 演示", .purple); if let summary = store.wechatSummary { insight("公众号昨日数据已接入", "净增 \(summary.newFollowers)，阅读 \(summary.articleReads)", .green) } else { insight("公众号内容可以复用", "连接后这里会显示真实昨日数据", .green) } }.padding(16).frame(width: 270, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)) }; HStack(alignment: .top, spacing: 14) { VStack(alignment: .leading, spacing: 8) { Text("平台表现").font(.system(size: 14, weight: .semibold)); LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) { ForEach(store.displayPlatforms) { PlatformCard(item: $0) } } }.frame(maxWidth: .infinity); VStack(alignment: .leading, spacing: 8) { Text("最近内容").font(.system(size: 14, weight: .semibold)); ForEach(store.contents.prefix(4)) { ContentRow(item: $0) } }.padding(16).frame(width: 390, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)) } }.padding(.top, 1) }
    func insight(_ title: String, _ detail: String, _ color: Color) -> some View { HStack(alignment: .top, spacing: 8) { Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) } } }
    var contentView: some View { VStack(alignment: .leading, spacing: 12) { HStack { VStack(alignment: .leading, spacing: 4) { Text("内容库").font(.system(size: 17, weight: .bold)); Text("先接入公众号官方草稿箱，其他平台继续支持后台 CSV 导入。").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Button { store.loadWeChatDrafts() } label: { Label("刷新公众号草稿", systemImage: "arrow.clockwise") }.controlSize(.small) }; HStack { Text(store.wechatDraftStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(store.wechatDraftStatus.contains("官方") ? .green : .secondary); Spacer() }.padding(.bottom, 2); if !store.wechatDrafts.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("公众号草稿箱").font(.system(size: 13, weight: .semibold)); ForEach(store.wechatDrafts) { draft in HStack { Image(systemName: "doc.text").foregroundStyle(.green); VStack(alignment: .leading, spacing: 3) { Text(draft.title).font(.system(size: 12, weight: .medium)); Text("\(draft.articleCount) 篇图文 · \(draft.updateTime.map { Self.dateFormatter.string(from: $0) } ?? "时间未知")").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Text("草稿").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange) }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)) } }.padding(.bottom, 6) }; ForEach(store.contents) { ContentRow(item: $0).padding(.horizontal, 12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) } }.padding(.top, 10) }
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
        if let button = status.button { button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "汇芯 内容创业管家"); button.image?.isTemplate = true; button.toolTip = "汇芯 内容创业管家"; button.target = self; button.action = #selector(toggle) }
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
    func showWindow() { let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false); w.title = "汇芯 内容创业管家"; w.contentView = NSHostingView(rootView: Dashboard(store: store)); w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window = w }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
