import Foundation

public enum Hongguo {
    public static let siteKey = "builtin.hongguo"
    static let mediaReferer = "https://novelquickapp.com/"
    static var configuration: JSONValue {
        .object([
            "name": .string(L10n.text("Hongguo")),
            "episode": .string(L10n.text("Episode %@")),
            "categories": .array([
                L10n.text("Live-action Drama"), L10n.text("Animated Drama"), L10n.text("AI Drama"),
                L10n.text("Trending Dramas"), L10n.text("Trending Live-action"), L10n.text("Trending Animation"), L10n.text("Trending AI Drama")
            ].map(JSONValue.string)),
            "unavailable": .string(L10n.text("Hongguo could not be reached. Try again later.")),
            "changed": .string(L10n.text("Hongguo returned incomplete data. Please refresh and try again.")),
            "playback": .string(L10n.text("Hongguo did not provide a playable source for this episode. Try again later."))
        ])
    }
}

extension Site {
    public static let hongguo: Site = {
        let name = L10n.text("Hongguo")
        let raw: [String: JSONValue] = ["key": .string(Hongguo.siteKey), "name": .string(name), "type": .number(3),
                                       "api": .string("csp_YingxiaHongguo"), "searchable": .number(1), "quickSearch": .number(1)]
        return Site(key: Hongguo.siteKey, name: name, type: 3, api: "csp_YingxiaHongguo", raw: raw)
    }()
}
