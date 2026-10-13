import Foundation

/// Douyin (抖音) Live as a built-in platform: its recommended rooms, its categories (whose room lists
/// need the `a_bogus` signature, `DouyinSign`), search for signed-in accounts, and HLS streams.
enum DouyinLive {
    /// What Douyin's web pages send; the browser fields agree with the User-Agent the signature binds.
    private static let parameters: [(String, String)] = [
        ("aid", "6383"), ("app_name", "douyin_web"), ("live_id", "1"), ("device_platform", "web"), ("language", "zh-CN"),
        ("browser_language", "zh-CN"), ("browser_platform", "Win32"), ("browser_name", "Chrome"), ("browser_version", "126.0.0.0"),
        ("cookie_enabled", "true"), ("screen_width", "1920"), ("screen_height", "1080"),
    ]
    private static let cookie = DouyinCookie()
    /// The top-level categories when the live home page can't be read.
    private static let fallbackAreas = [("101", "聊天"), ("102", "音乐"), ("103", "游戏"), ("104", "二次元"), ("105", "舞蹈"), ("106", "文化"), ("107", "生活"), ("108", "运动")]
        .map { LiveArea(id: $0.0 + ",4", name: $0.1) }

    /// Recommendations, then the categories (each game category after 游戏), ids `<partition>,<type>`.
    static func areas() async throws -> [LiveArea] {
        [.recommended] + ((try? await categories()).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackAreas)
    }

    /// The categories the live home page lists, from the data it embeds as an escaped JSON string.
    private static func categories() async throws -> [LiveArea] {
        let html = try await LiveHTTP.text(URL(string: "https://live.douyin.com/")!, headers: try await headers())
        guard let start = html.range(of: #"\"categoryData\":["#) else { return [] }
        let escaped = String(html[html.index(before: start.upperBound)...].prefix(300_000))
        let text = escaped.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
        guard let array = firstJSONValue(text), let list = (try? JSONDecoder().decode(JSONValue.self, from: array))?.array else { return [] }
        func area(_ item: JSONValue) -> LiveArea? {
            guard let partition = item.object?["partition"]?.object, let id = partition["id_str"]?.string,
                  let type = partition["type"]?.int, let title = partition["title"]?.string, !title.isEmpty else { return nil }
            return LiveArea(id: "\(id),\(type)", name: title)
        }
        return list.flatMap { item in
            [area(item)].compactMap { $0 } + (item.object?["sub_partition"]?.array ?? []).compactMap(area)
        }
    }

    /// The bytes of the JSON array or object `text` starts with.
    private static func firstJSONValue(_ text: String) -> Data? {
        var depth = 0, inString = false, escaped = false
        let bytes = Array(text.utf8)
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return Data(bytes[...index]) }
            default: break
            }
        }
        return nil
    }

    static func rooms(area: LiveArea, page: Int) async throws -> [LiveRoom] {
        guard !area.id.isEmpty else { return try await recommended(page: page) }
        let parts = area.id.split(separator: ",").map(String.init)
        guard parts.count == 2 else { return [] }
        let url = signed("https://live.douyin.com/webcast/web/partition/detail/room/v2/", parameters + [
            ("enter_from", "link_share"), ("browser_online", "true"), ("count", "15"), ("offset", String((page - 1) * 15)),
            ("partition", parts[0]), ("partition_type", parts[1]), ("req_from", "2"),
        ])
        let reply = try await LiveHTTP.json(url, headers: try await headers())
        let items = reply["data"]?.object?["data"]?.array?.compactMap(\.object) ?? []
        return items.compactMap { item in
            guard let id = item["web_rid"]?.string, !id.isEmpty, let room = item["room"]?.object else { return nil }
            let stats = room["room_view_stats"]?.object?["display_value"]
            let tag = item["tag_name"]?.string ?? ""
            return LiveRoom(platform: .douyin, roomID: id, title: room["title"]?.string ?? "", host: room["owner"]?.object?["nickname"]?.string ?? "",
                            cover: room["cover"]?.object?["url_list"]?.array?.first?.string, online: stats?.int ?? LiveText.count(stats?.string),
                            area: tag.isEmpty ? area.name : tag)
        }
    }

    /// The recommendation feed answers with a fresh selection each time, so every page is a new one.
    private static func recommended(page: Int) async throws -> [LiveRoom] {
        guard page <= 6 else { return [] }
        let url = LiveHTTP.url("https://live.douyin.com/webcast/feed/", parameters + [
            ("need_map", "1"), ("is_draw", "1"), ("inner_from_drawer", "0"), ("count", "20"),
            ("enter_source", "web_homepage_hot_web_live_card"), ("source_key", "web_homepage_hot_web_live_card"),
        ])
        let reply = try await LiveHTTP.json(url, headers: try await headers())
        let items = reply["data"]?.array?.compactMap { $0.object?["data"]?.object } ?? []
        return items.compactMap { room in
            let owner = room["owner"]?.object
            guard let id = (room["web_rid"] ?? owner?["web_rid"])?.string, !id.isEmpty else { return nil }
            return LiveRoom(platform: .douyin, roomID: id, title: room["title"]?.string ?? "", host: owner?["nickname"]?.string ?? "",
                            cover: room["cover"]?.object?["url_list"]?.array?.first?.string, online: room["user_count"]?.int ?? 0,
                            area: L10n.text("Recommended"))
        }
    }

    /// Live rooms matching `keyword`; Douyin answers only signed-in accounts.
    static func search(_ keyword: String, page: Int) async throws -> [LiveRoom] {
        let account = DouyinAccount.load()
        guard account.signedIn else { throw TVError.unsupported(L10n.text("Sign in to Douyin to search its live rooms.")) }
        let url = signed("https://www.douyin.com/aweme/v1/web/live/search/", [
            ("device_platform", "webapp"), ("aid", "6383"), ("channel", "channel_pc_web"), ("search_channel", "aweme_live"), ("keyword", keyword),
            ("search_source", "switch_tab"), ("query_correct_type", "1"), ("is_filter_search", "0"), ("from_group_id", ""),
            ("offset", String((page - 1) * 10)), ("count", "10"), ("pc_client_type", "1"), ("version_code", "170400"), ("version_name", "17.4.0"),
            ("cookie_enabled", "true"), ("screen_width", "1920"), ("screen_height", "1080"), ("browser_language", "zh-CN"), ("browser_platform", "Win32"),
            ("browser_name", "Chrome"), ("browser_version", "126.0.0.0"), ("browser_online", "true"), ("engine_name", "Blink"), ("engine_version", "126.0.0.0"),
            ("os_name", "Windows"), ("os_version", "10"), ("platform", "PC"),
        ])
        let referer = "https://www.douyin.com/search/\(keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")?type=live"
        let reply = try await LiveHTTP.json(url, headers: ["Cookie": account.cookie, "Referer": referer, "User-Agent": DouyinSign.userAgent,
                                                          "Accept": "application/json, text/plain, */*"])
        if let status = reply["status_code"]?.int, status != 0 {
            // 2483 is "sign in to keep searching": the sign-in was refused.
            throw TVError.unsupported(status == 2483 ? L10n.text("Douyin no longer accepts this sign-in. Sign in again in Settings.")
                                                     : reply["status_msg"]?.string ?? L10n.text("%@ could not be reached. Try again later.", LivePlatform.douyin.name))
        }
        return (reply["data"]?.array ?? []).compactMap { item -> LiveRoom? in
            guard let raw = item.object?["lives"]?.object?["rawdata"]?.string,
                  let room = try? JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8)) else { return nil }
            let owner = room["owner"]?.object
            guard let id = owner?["web_rid"]?.string, !id.isEmpty, (room["status"]?.int ?? 2) == 2 else { return nil }
            return LiveRoom(platform: .douyin, roomID: id, title: room["title"]?.string ?? "", host: owner?["nickname"]?.string ?? "",
                            cover: room["cover"]?.object?["url_list"]?.array?.first?.string,
                            online: room["stats"]?.object?["total_user"]?.int ?? room["user_count"]?.int ?? 0, area: LivePlatform.douyin.name)
        }
    }

    /// Douyin's HLS names, best first, with the quality ids the player offers.
    private static let levels: [(key: String, id: Int, label: String)] = [
        ("FULL_HD1", 4, L10n.text("Original")), ("HD1", 3, L10n.text("Super HD")), ("SD1", 2, L10n.text("HD")), ("SD2", 1, L10n.text("SD")),
    ]

    static func stream(room: String, quality: Int?) async throws -> LiveStream {
        let url = LiveHTTP.url("https://live.douyin.com/webcast/room/web/enter/", parameters + [("web_rid", room), ("enter_from", "web_live"), ("is_need_double_stream", "false")])
        var request = try await headers()
        request["Referer"] = "https://live.douyin.com/\(room)"
        let reply = try await LiveHTTP.json(url, headers: request)
        let data = reply["data"]?.object
        guard let info = data?["data"]?.array?.first?.object, info["status"]?.int == 2,
              let map = info["stream_url"]?.object?["hls_pull_url_map"]?.object else {
            throw TVError.unsupported(L10n.text("This live room is not broadcasting right now."))
        }
        let offered = levels.filter { !(map[$0.key]?.string ?? "").isEmpty }
        guard let chosen = offered.first(where: { $0.id == quality }) ?? offered.first,
              let address = map[chosen.key]?.string, let url = URL(string: address) else {
            throw TVError.unsupported(L10n.text("This live room has no stream this device can play."))
        }
        // The CDN's HLS hosts answer over plain HTTP only, so the address is kept as served.
        return LiveStream(url: url, title: info["title"]?.string, qualities: offered.map { (id: $0.id, label: $0.label) }, current: chosen.id)
    }

    /// `base` with `query` and its `a_bogus` signature, computed over the query exactly as sent.
    private static func signed(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(url: LiveHTTP.url(base, query), resolvingAgainstBaseURL: false)!
        let sent = components.percentEncodedQuery ?? ""
        let signature = DouyinSign.aBogus(query: sent).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        components.percentEncodedQuery = sent + "&a_bogus=" + signature
        return components.url!
    }

    private static func headers() async throws -> [String: String] {
        ["Referer": "https://live.douyin.com/", "Cookie": try await cookie.value(), "User-Agent": DouyinSign.userAgent]
    }
}

/// Douyin's web APIs answer only with a `ttwid` visitor cookie, which its home page hands out.
private actor DouyinCookie {
    private var cached: String?
    func value() async throws -> String {
        if let cached { return cached }
        let (_, response) = try await LiveHTTP.data(URL(string: "https://live.douyin.com/")!, headers: ["Accept": "text/html", "User-Agent": DouyinSign.userAgent])
        let header = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        let home = URL(string: "https://live.douyin.com/")!
        // The shared session may already have taken the cookie into its store.
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: home) + (HTTPCookieStorage.shared.cookies(for: home) ?? [])
        guard let ttwid = cookies.first(where: { $0.name == "ttwid" }) else {
            throw TVError.unsupported(L10n.text("%@ could not be reached. Try again later.", LivePlatform.douyin.name))
        }
        cached = "ttwid=\(ttwid.value)"
        return cached!
    }
}
