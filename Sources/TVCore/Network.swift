import Foundation

public struct HTTPClient: Sendable {
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    // Subscription hosts often send a landing page to browser user agents.
    public static let subscriptionUserAgent = "okhttp/3.12.13"
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, URL) {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        guard data.count <= 20_000_000 else { throw TVError.unsupported(L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")) }
        return (data, response.url ?? url)
    }
    public func subscription(_ url: URL) async throws -> Subscription {
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent])
        do {
            return try Subscription.parse(data, origin: finalURL)
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
            return Subscription(origin: finalURL, importedAt: Date(), sites: [],
                                lives: [LiveSource(name: name, url: finalURL)], raw: [:])
        }
    }
    public func channels(_ source: LiveSource) async throws -> [Channel] {
        if source.isBuiltIn { return try await BilibiliLive.channels() }
        let (data, finalURL) = try await get(source.url, headers: source.headers)
        guard let text = String(data: data, encoding: .utf8) else { throw TVError.unsupported(L10n.text("Live playlists must use UTF-8 encoding.")) }
        return try Playlist.parse(text, origin: finalURL, headers: source.headers)
    }

    /// First non-whitespace byte decides the error path: `{`/`[` is TVBox JSON
    /// (even when invalid), anything else may be an M3U/TXT playlist.
    private static func looksLikeJSON(_ data: Data) -> Bool {
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
