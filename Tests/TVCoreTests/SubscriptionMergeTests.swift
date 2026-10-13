import Foundation
import Testing
@testable import TVCore

private let first = URL(string: "https://one.example/tv/a.json")!
private let second = URL(string: "https://two.example/box/b.json")!
private func subscription(_ document: [String: Any], origin: URL) throws -> Subscription {
    try Subscription.parse(JSONSerialization.data(withJSONObject: document), origin: origin)
}
private func site(_ key: String, _ name: String, type: Int, api: String) -> [String: Any] {
    ["key": key, "name": name, "type": type, "api": api]
}

@Test func mergedSourcesKeepTheirOwnSubscription() throws {
    let a = try subscription(["spider": "./a.jar", "sites": [site("vod", "A", type: 1, api: "./api.php"), site("csp", "J", type: 3, api: "csp_A")]], origin: first)
    let b = try subscription(["spider": "./b.jar", "sites": [site("vod", "B", type: 1, api: "./api.php"), site("csp", "K", type: 3, api: "csp_B")]], origin: second)
    let merged = try #require(Subscription.merge([a, b]))
    #expect(merged.sites.map { $0.key } == ["vod", "csp", "vod@" + b.tag, "csp@" + b.tag])
    // Plugins, history and pins see the key the subscription wrote.
    #expect(merged.sites.map { $0.sourceKey } == ["vod", "csp", "vod", "csp"])

    // Callers pass the merged subscription's origin and spider; each source still uses its own.
    let vodB = CatalogClient(site: merged.sites[2], origin: merged.origin, jarURL: merged.spiderURL)
    #expect(try vodB.requestURL(["ac": "detail"]).host() == "two.example")
    #expect(vodB.jarURL?.absoluteString == "https://two.example/box/b.jar")
    let jarA = CatalogClient(site: merged.sites[1], origin: merged.origin, jarURL: merged.spiderURL)
    #expect(jarA.jarURL?.absoluteString == "https://one.example/tv/a.jar")
    #expect(Set(merged.pluginArchives.map { $0.lastPathComponent }) == ["a.jar", "b.jar"])

    // History and pins made before merging still find the first subscription's sources.
    let video = try #require(Video(json: ["vod_id": .string("1"), "vod_name": .string("V")], origin: second))
    let context = PlaybackHistoryContext(origin: merged.origin, site: merged.sites[2], video: video,
                                         episode: Episode(id: "1", name: "1", address: "x", flag: "f", videoID: "1"))
    #expect(context.origin == second && context.sourceKey == "vod")
}

@Test func sameSourceInTwoSubscriptionsAppearsOnce() throws {
    let a = try subscription(["sites": [site("x", "X", type: 1, api: "https://api.example/vod"), site("y", "Y", type: 1, api: "https://api.example/vod")]], origin: first)
    let b = try subscription(["sites": [site("z", "Z", type: 1, api: "https://api.example/vod"), site("w", "W", type: 1, api: "../box/other")]], origin: second)
    let merged = try #require(Subscription.merge([a, b]))
    // Repeats inside one subscription stay; the later subscription's copy is dropped.
    #expect(merged.sites.map { $0.key } == ["x", "y", "w"])
}

@Test func oneSubscriptionMergesToItself() throws {
    let a = try subscription(["spider": "./a.jar", "sites": [site("vod", "A", type: 1, api: "./api.php")], "parses": [["name": "p", "type": 1, "url": "https://p.example/?url="]]], origin: first)
    let merged = try #require(Subscription.merge([a]))
    #expect(merged.sites.map { $0.key } == a.sites.map { $0.key })
    #expect(merged.origin == a.origin && merged.spiderURL == a.spiderURL)
    #expect(merged.parseServices.count == 1)
    #expect(Subscription.merge([]) == nil)
}

@Test func livesAndParsesJoinWithoutRepeats() throws {
    let parse: [String: Any] = ["name": "p", "type": 1, "url": "https://p.example/?url="]
    let a = try subscription(["lives": [["name": "L", "url": "https://live.example/a.m3u"]], "parses": [parse]], origin: first)
    let b = try subscription(["lives": [["name": "L2", "url": "https://live.example/a.m3u"], ["name": "M", "url": "./m.txt"]],
                              "parses": [parse, ["name": "q", "type": 1, "url": "https://q.example/?url="]]], origin: second)
    let merged = try #require(Subscription.merge([a, b]))
    #expect(merged.lives.map { $0.url.absoluteString } == ["https://live.example/a.m3u", "https://two.example/box/m.txt"])
    #expect(merged.parseServices.map { $0.name } == ["p", "q"])
}

@Test func directoriesListTheirSubscriptions() throws {
    let urls = try JSONSerialization.data(withJSONObject: ["urls": [["name": "One", "url": "./one.json"], ["name": "Again", "url": "https://one.example/tv/one.json"]]])
    let entries = try #require(Subscription.directory(urls, origin: first))
    #expect(entries == [SubscriptionEntry(address: "https://one.example/tv/one.json", name: "One", enabled: false)])

    let house = try JSONSerialization.data(withJSONObject: ["storeHouse": [["sourceName": "Repo", "sourceUrl": "https://repo.example/dc"]]])
    #expect(Subscription.directory(house, origin: first)?.map { $0.title } == ["Repo"])

    let plain = try JSONSerialization.data(withJSONObject: ["sites": [site("a", "A", type: 1, api: "./a")]])
    #expect(Subscription.directory(plain, origin: first) == nil)
    #expect(SubscriptionEntry(address: "https://www.repo.example/dc").title == "repo.example · dc")
    #expect(SubscriptionEntry(address: "https://raw.githubusercontent.com/qist/tvbox/master/fty.json").title == "qist/tvbox · fty.json")
    #expect(SubscriptionEntry(address: "https://repo.example").title == "repo.example")
}
