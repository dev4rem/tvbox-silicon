import Foundation

/// Douyu (斗鱼) as a built-in live platform. Rooms come from its web directory; streams from its
/// mobile site's API, which answers with HLS (the desktop API serves FLV, which AVPlayer can't play).
/// That API wants a signature made by a script Douyu serves per room, run here in QuickJS.
enum DouyuLive {
    /// A device id for this launch, as the web player makes one.
    private static let device = LiveHTTP.randomHex(32)

    static func areas() async throws -> [LiveArea] {
        let reply = try await LiveHTTP.json(URL(string: "https://m.douyu.com/api/cate/list")!)
        let categories = reply["data"]?.object?["cate1Info"]?.array?.compactMap(\.object) ?? []
        return [.recommended] + categories.compactMap { category in
            guard let id = category["cate1Id"]?.int, let name = category["cate1Name"]?.string else { return nil }
            return LiveArea(id: "1_\(id)", name: name)
        }
    }

    static func rooms(area: LiveArea, page: Int) async throws -> [LiveRoom] {
        let address = area.id.isEmpty ? "https://www.douyu.com/japi/weblist/apinc/allpage/6/\(page)"
            : "https://www.douyu.com/gapi/rkc/directory/mixList/\(area.id)/\(page)"
        let reply = try await LiveHTTP.json(URL(string: address)!)
        let rooms = reply["data"]?.object?["rl"]?.array?.compactMap(\.object) ?? []
        // Type 1 is a live room; the others are videos and ads mixed into the directory.
        return rooms.filter { $0["type"]?.int == 1 }.compactMap { room in
            guard let id = room["rid"]?.string else { return nil }
            return LiveRoom(platform: .douyu, roomID: id, title: room["rn"]?.string ?? "", host: room["nn"]?.string ?? "",
                            cover: room["rs16"]?.string ?? room["rs1"]?.string, online: room["ol"]?.int ?? 0,
                            area: room["c2name"]?.string ?? area.name)
        }
    }

    static func search(_ keyword: String, page: Int) async throws -> [LiveRoom] {
        let url = LiveHTTP.url("https://www.douyu.com/japi/search/api/searchShow", [("kw", keyword), ("page", "\(page)"), ("pageSize", "20")])
        let reply = try await LiveHTTP.json(url, headers: ["Referer": "https://www.douyu.com/search/", "Cookie": "dy_did=\(device); acf_did=\(device)"])
        guard reply["error"]?.int == 0 else { throw TVError.unsupported(reply["msg"]?.string ?? L10n.text("%@ could not be reached. Try again later.", LivePlatform.douyu.name)) }
        let rooms = reply["data"]?.object?["relateShow"]?.array?.compactMap(\.object) ?? []
        return rooms.compactMap { room in
            guard let id = room["rid"]?.string else { return nil }
            return LiveRoom(platform: .douyu, roomID: id, title: room["roomName"]?.string ?? "", host: room["nickName"]?.string ?? "",
                            cover: room["roomSrc"]?.string, online: LiveText.count(room["hot"]?.string),
                            area: room["cateName"]?.string ?? LivePlatform.douyu.name)
        }
    }

    /// `quality` is Douyu's rate: 0 is the original.
    static func stream(room: String, quality: Int?) async throws -> LiveStream {
        let enc = try await LiveHTTP.json(URL(string: "https://www.douyu.com/swf_api/homeH5Enc?rids=\(room)")!, headers: ["Referer": "https://www.douyu.com/\(room)"])
        guard let script = enc["data"]?.object?["room\(room)"]?.string, !script.isEmpty else {
            throw TVError.unsupported(L10n.text("This live room is not broadcasting right now."))
        }
        let time = Int(Date().timeIntervalSince1970)
        let signed = try await LiveScript.evaluate(script, then: "ub98484234('\(room)', '\(device)', '\(time)')")
        let reply = try await LiveHTTP.json(URL(string: "https://m.douyu.com/hgapi/livenc/room/getStreamUrl")!,
                                            headers: ["User-Agent": LiveHTTP.mobileAgent, "Referer": "https://m.douyu.com/\(room)"],
                                            form: signed + "&ver=22107261&rid=\(room)&rate=\(quality ?? 0)")
        let data = reply["data"]?.object
        guard reply["error"]?.int == 0, let address = data?["url"]?.string, !address.isEmpty,
              let url = URL(string: address.replacingOccurrences(of: "http://", with: "https://")) else {
            Diagnostics.shared.record(.warning, "live", "douyu room=\(room) error=\(reply["error"]?.string ?? "-") msg=\(reply["msg"]?.string ?? "-")")
            throw TVError.unsupported(L10n.text("This live room is not broadcasting right now."))
        }
        let qualities = (data?["settings"]?.array?.compactMap(\.object) ?? []).compactMap { setting -> (Int, String)? in
            guard let rate = setting["rate"]?.int, let name = setting["name"]?.string else { return nil }
            return (rate, name)
        } // Best first, as Douyu lists them (0 is the original, then 4, 3, 2…).
        return LiveStream(url: url, headers: ["User-Agent": LiveHTTP.mobileAgent, "Referer": "https://m.douyu.com/"],
                          qualities: qualities.map { (id: $0.0, label: $0.1) }, current: data?["rate"]?.int ?? quality ?? 0)
    }
}
