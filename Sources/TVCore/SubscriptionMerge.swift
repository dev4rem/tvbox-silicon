import Foundation

/// Where a merged source came from. Its relative addresses, `ext` and default spider resolve
/// against its own subscription, never against the first one in the list.
public struct SourceProvenance: Codable, Hashable, Sendable {
    public let origin: URL
    public let spider: URL?
    public init(origin: URL, spider: URL?) { self.origin = origin; self.spider = spider }
}

extension Site {
    /// The key the subscription gave this source. `key` differs only when a merge renamed a clash;
    /// plugins, history and per-source settings keep using this one.
    public var sourceKey: String { raw["key"]?.string ?? key }
    /// The address this source resolves against: its own subscription's, else `fallback`.
    public func origin(or fallback: URL) -> URL { provenance?.origin ?? fallback }
    /// The spider archive a JAR source without its own `jar` runs from.
    public func spider(or fallback: URL?) -> URL? { provenance.map(\.spider) ?? fallback }

    /// Two entries are one source when they run the same way once their addresses are resolved.
    func fingerprint(origin: URL, spider: URL?) -> String {
        let api = runtime == .jar ? self.api : ((try? WebAddress.resolve(self.api, relativeTo: origin).absoluteString) ?? self.api)
        let archive = runtime == .jar ? (try? pluginURL(origin: origin, fallback: spider))?.absoluteString ?? "" : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let ext = (try? pluginExtension(origin: origin)).flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [String(type), api, archive, ext].joined(separator: "\n")
    }
}

extension Subscription {
    /// Several subscriptions shown as one, in the order given.
    ///
    /// Each source keeps its own subscription (`provenance`), so it resolves and runs as it did
    /// alone. A source an earlier subscription already offers, the same once resolved, appears
    /// once; repeats inside one subscription stay, as they always have. Unrelated sources often
    /// share a key across subscriptions, so a later one gets its subscription's tag on the key and
    /// keeps the original as `sourceKey`. Live playlists and parse services are joined without repeats.
    public static func merge(_ parts: [Subscription]) -> Subscription? {
        guard let first = parts.first else { return nil }
        var sites: [Site] = [], keys = Set<String>(), offered = Set<String>()
        var lives: [LiveSource] = [], liveURLs = Set<URL>()
        var parses: [JSONValue] = [], parseURLs = Set<String>()
        for part in parts {
            let provenance = SourceProvenance(origin: part.origin, spider: part.spiderURL)
            var own = Set<String>()
            for var site in part.sites {
                let fingerprint = site.fingerprint(origin: part.origin, spider: part.spiderURL)
                guard !offered.contains(fingerprint) else { continue }
                own.insert(fingerprint)
                if !keys.insert(site.key).inserted {
                    let renamed = site.key + "@" + part.tag
                    guard keys.insert(renamed).inserted else { continue }
                    site = Site(key: renamed, name: site.name, type: site.type, api: site.api, raw: site.raw)
                }
                site.provenance = provenance
                sites.append(site)
            }
            offered.formUnion(own)
            for live in part.lives where liveURLs.insert(live.url).inserted { lives.append(live) }
            for parse in part.raw["parses"]?.array ?? [] {
                guard let url = parse.object?["url"]?.string, parseURLs.insert(url).inserted else { continue }
                parses.append(parse)
            }
        }
        var raw = first.raw
        if !parses.isEmpty { raw["parses"] = .array(parses) }
        return Subscription(origin: first.origin, importedAt: parts.map(\.importedAt).max() ?? first.importedAt,
                            sites: sites, lives: lives, raw: raw)
    }

    /// A short, stable tag for this subscription's address.
    var tag: String { String(PluginChecksum.sha256(Data(origin.absoluteString.utf8)).prefix(6)) }

    /// The subscriptions a directory (多仓) lists: `urls` as [{name, url}], or `storeHouse` as
    /// [{sourceName, sourceUrl}]. Nil when the document is not a directory.
    public static func directory(_ data: Data, origin: URL) -> [SubscriptionEntry]? {
        guard let raw = try? SubscriptionDocument.decode(data), raw["sites"] == nil, raw["lives"] == nil else { return nil }
        var seen = Set<String>()
        let entries = ((raw["urls"]?.array ?? []) + (raw["storeHouse"]?.array ?? [])).compactMap { item -> SubscriptionEntry? in
            guard let fields = item.object, let text = (fields["url"] ?? fields["sourceUrl"])?.string,
                  let url = try? WebAddress.resolve(text, relativeTo: origin), seen.insert(url.absoluteString).inserted else { return nil }
            return SubscriptionEntry(address: url.absoluteString, name: (fields["name"] ?? fields["sourceName"])?.string ?? "", enabled: false)
        }
        return entries.isEmpty ? nil : entries
    }
}

/// A subscription the viewer added. Any number can be on; the app shows them merged, in list order.
public struct SubscriptionEntry: Codable, Hashable, Identifiable, Sendable {
    public var address: String
    public var name: String
    public var enabled: Bool
    public var id: String { address }
    public init(address: String, name: String = "", enabled: Bool = true) {
        self.address = address; self.name = name; self.enabled = enabled
    }
    /// Its name, else where it lives and its file: many subscriptions share a host such as
    /// raw.githubusercontent.com, so a GitHub address reads as its repository.
    public var title: String {
        guard name.isEmpty else { return name }
        guard let url = URL(string: address), let host = url.host() else { return address }
        let parts = url.pathComponents.filter { $0 != "/" }
        let place = host == "raw.githubusercontent.com" && parts.count > 2 ? parts[0] + "/" + parts[1]
            : host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return parts.last.map { place + " · " + $0 } ?? place
    }
    /// The file name its last good copy is kept under.
    public var cacheName: String { PluginChecksum.sha256(Data(address.utf8)) + ".json" }
}

/// What an added address holds: one subscription, or a directory that lists several.
public enum SubscriptionImport: Sendable {
    case subscription(Subscription)
    case directory([SubscriptionEntry])
}

extension HTTPClient {
    public func subscriptionImport(_ url: URL) async throws -> SubscriptionImport {
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent])
        if let entries = Subscription.directory(data, origin: finalURL) { return .directory(entries) }
        do {
            return .subscription(try Subscription.parse(data, origin: finalURL))
        } catch let jsonError {
            // A raw M3U/TXT playlist is also importable as a single live source.
            // JSON-looking bodies keep the original error (directory, landing page,
            // encrypted config), which explains the problem better than a playlist error.
            if Self.looksLikeJSON(data) { throw jsonError }
            guard let text = String(data: data, encoding: .utf8) else {
                throw TVError.unsupported(L10n.text("Live playlists must use UTF-8 encoding."))
            }
            do {
                _ = try Playlist.parse(text, origin: finalURL)
            } catch {
                // Neither TVBox JSON nor a playlist: the JSON error is the actionable one.
                throw jsonError
            }
            let stem = finalURL.deletingPathExtension().lastPathComponent
            let name = stem.isEmpty ? (finalURL.host ?? L10n.text("Live TV")) : stem
            return .subscription(Subscription(origin: finalURL, importedAt: Date(), sites: [],
                                             lives: [LiveSource(name: name, url: finalURL)], raw: [:]))
        }
    }

    /// First non-whitespace byte decides the error path: `{`/`[` is TVBox JSON
    /// (even when invalid), anything else may be an M3U/TXT playlist.
    static func looksLikeJSON(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 9, 10, 13, 32: continue
            case 0xEF: continue // Allow a UTF-8 BOM before the document.
            case 0xBB, 0xBF: continue
            case 123, 91: return true // { or [
            default: return false
            }
        }
        return false
    }
}
