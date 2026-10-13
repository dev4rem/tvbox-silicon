import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    let searchModel = SearchModel()
    /// Song search and the music player; both outlive the Music page, so a song keeps playing elsewhere in the app.
    let musicSearch = MusicSearchModel()
    let music = MusicPlaybackSession()
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// Every enabled subscription merged in list order, plus the built-in sources.
    /// When `activeAddress` names one of them, only that subscription is shown.
    var activeAddress: String?
    var subscription: Subscription?
    /// The address being typed in to add a subscription.
    var subscriptionAddress: String
    /// Every subscription the viewer added, in the order they merge.
    var subscriptions: [SubscriptionEntry] = []
    /// Why a subscription last failed to refresh, by address; its last good copy stays in use.
    var subscriptionErrors: [String: String] = [:]
    /// The last good copy of each subscription, by address.
    private(set) var documents: [String: Subscription] = [:]
    var favorites: [Channel] = []
    var importing = false
    var error: String?
    var notice: String?
    var playing: Channel?
    var playbackCatalog: PlaybackCatalog?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    var section: AppSection = .home
    private let defaults: UserDefaults
    private let http = HTTPClient()
    private var persistsChanges: Bool {
        #if DEBUG
        return !defaults.bool(forKey: "qaIsolatedData")
        #else
        return true
        #endif
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        playbackDefaults = defaults.bool(forKey: "qaIsolatedData")
            ? UserDefaults(suiteName: "com.tcbox.tvbox.qa.player") ?? defaults : defaults
        playbackHistory = defaults.bool(forKey: "qaIsolatedData")
            ? PlaybackHistory(file: URL.cachesDirectory.appending(path: "qa-player-history.json"), defaults: playbackDefaults) : .shared
        #else
        playbackDefaults = defaults
        playbackHistory = .shared
        #endif
        pinnedSources = PinnedSources(defaults: playbackDefaults)
        autoPlayNext = defaults.object(forKey: "autoPlayNextEpisode") == nil || defaults.bool(forKey: "autoPlayNextEpisode")
        let saved = defaults.data(forKey: "subscriptions").flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) }
        var entries = saved ?? [], copies: [String: Subscription] = [:]
        for entry in entries {
            if let data = try? Data(contentsOf: Self.file(for: entry)),
               let value = try? JSONDecoder().decode(Subscription.self, from: data) { copies[entry.address] = value }
        }
        // Builds before several subscriptions kept one, in subscription.json, and before that in defaults.
        let legacyAddress = saved == nil ? defaults.string(forKey: "subscriptionAddress") : nil
        let legacy = legacyAddress == nil ? nil : (try? Data(contentsOf: Self.legacyFile)) ?? defaults.data(forKey: "subscription")
        if let legacyAddress {
            entries = [SubscriptionEntry(address: legacyAddress)]
            copies[legacyAddress] = legacy.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        }
        subscriptions = entries
        documents = copies
        subscriptionAddress = entries.isEmpty ? Self.defaultURL : ""
        if persistsChanges, let legacyAddress {
            if let legacy, copies[legacyAddress] != nil { try? Self.save(legacy, to: Self.file(for: entries[0])) }
            saveSubscriptionList()
            try? FileManager.default.removeItem(at: Self.legacyFile)
            defaults.removeObject(forKey: "subscription")
        }
        activeAddress = defaults.string(forKey: "activeSubscriptionAddress")
        migrateSidecarEntries()
        rebuildSubscription(resetting: false)
        if let data = defaults.data(forKey: "favorites") { favorites = (try? JSONDecoder().decode([Channel].self, from: data)) ?? [] }
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
    }
    /// The current media address of a downloading episode, from its source; the queue asks again when a link expires.
    private func resolveDownload(_ item: DownloadItem) async throws -> Channel {
        let config = subscription
        guard let site = config?.sites.first(where: { $0.key == item.source.siteKey })
                ?? Site.builtInSites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so this download can't continue.", item.source.siteName))
        }
        let client = CatalogClient(site: site, origin: config?.origin ?? URL(string: "https://example.invalid/")!, jarURL: config?.spiderURL)
            .with(parses: config?.parseServices ?? [])
        let plan = try await client.preparePlayback(item.source.episode, forDownload: true)
        let channel = try await client.resolvePlayback(plan, choice: plan.choices[0])
        // A cloud-drive file downloads straight from its CDN, as it plays: through the plugin's
        // proxy every part costs the embedded runtime download threads and interpreted TLS.
        let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            Diagnostics.shared.record(.info, "download", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        return address == channel.url ? channel : Channel(name: channel.name, group: channel.group, url: address, headers: channel.headers)
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches what is gone from the saved addresses.
    private static var subscriptionDirectory: URL {
        #if os(tvOS)
        return URL.cachesDirectory
        #else
        return URL.applicationSupportDirectory
        #endif
    }
    private static var legacyFile: URL { subscriptionDirectory.appending(path: "subscription.json") }
    private static func file(for entry: SubscriptionEntry) -> URL {
        subscriptionDirectory.appending(path: "subscriptions").appending(path: entry.cacheName)
    }
    private static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// TCBox builds kept side-by-side entries in `subscriptions.json` plus
    /// `subscription-<uuid>.json` files. Fold them into the shared list once.
    private func migrateSidecarEntries() {
        struct Sidecar: Codable {
            var id: UUID; var address: String; var displayName: String
            var siteCount: Int; var liveCount: Int; var importedAt: Date
        }
        guard let index = try? Data(contentsOf: Self.subscriptionDirectory.appending(path: "subscriptions.json")),
              let sidecars = try? JSONDecoder().decode([Sidecar].self, from: index) else { return }
        var changed = false
        for sidecar in sidecars {
            let file = Self.subscriptionDirectory.appending(path: "subscription-\(sidecar.id.uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(Subscription.self, from: data) else { continue }
            if !subscriptions.contains(where: { $0.address == sidecar.address }) {
                let entry = SubscriptionEntry(address: sidecar.address, name: sidecar.displayName)
                subscriptions.append(entry)
                documents[sidecar.address] = value
                if persistsChanges, let encoded = try? JSONEncoder().encode(value) {
                    try? Self.save(encoded, to: Self.file(for: entry))
                }
                changed = true
            }
            if activeAddress == nil,
               defaults.string(forKey: "activeSubscriptionID") == sidecar.id.uuidString,
               subscriptions.contains(where: { $0.address == sidecar.address }) {
                activeAddress = sidecar.address
            }
        }
        try? FileManager.default.removeItem(at: Self.subscriptionDirectory.appending(path: "subscriptions.json"))
        defaults.removeObject(forKey: "activeSubscriptionID")
        if changed { saveSubscriptionList() }
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches enabled subscriptions whose cached copy is gone.
    func restoreSubscription() async {
        let missing = subscriptions.filter { $0.enabled && documents[$0.address] == nil }
        guard !missing.isEmpty, !importing else { return }
        importing = true
        defer { importing = false }
        await fetch(missing)
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    func importSubscription(address: String? = nil) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        let typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed.isEmpty ? Self.defaultURL : typed)
            switch try await http.subscriptionImport(url) {
            case .subscription(let value):
                let entry = SubscriptionEntry(address: url.absoluteString)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) { subscriptions[index].enabled = true }
                else { subscriptions.append(entry) }
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
            }
            if address == nil { subscriptionAddress = "" }
            saveSubscriptionList()
            rebuildSubscription()
        } catch { self.error = L10n.text("Import failed: %@", error.localizedDescription) }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
    func refreshSubscriptions() async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        await fetch(subscriptions.filter(\.enabled))
        let failed = subscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil }.count
        if failed > 0 { notice = L10n.text("%lld subscriptions could not be refreshed; their last copies stay in use.", failed) }
    }
    func setSubscription(_ entry: SubscriptionEntry, enabled: Bool) async {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return }
        subscriptions[index].enabled = enabled
        saveSubscriptionList()
        if enabled, documents[entry.address] == nil { await restoreSubscription() } else { rebuildSubscription() }
    }
    func removeSubscription(_ entry: SubscriptionEntry) {
        subscriptions.removeAll { $0.address == entry.address }
        documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
        if activeAddress == entry.address {
            activeAddress = nil
            if persistsChanges { defaults.removeObject(forKey: "activeSubscriptionAddress") }
        }
        if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)) }
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Narrows the visible library to one subscription; nil shows every enabled one, merged.
    func selectSubscription(address: String?) {
        guard address != activeAddress else { return }
        activeAddress = address
        if persistsChanges {
            if let address { defaults.set(address, forKey: "activeSubscriptionAddress") }
            else { defaults.removeObject(forKey: "activeSubscriptionAddress") }
        }
        rebuildSubscription()
    }

    /// Fetches one subscription again; a failure keeps its last good copy.
    func refreshSubscription(_ entry: SubscriptionEntry) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        await fetch([entry])
    }
    /// Moves a subscription one place up (-1) or down (1); earlier subscriptions win duplicate sources.
    func moveSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }),
              subscriptions.indices.contains(index + offset) else { return }
        subscriptions.swapAt(index, index + offset)
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Fetches subscriptions side by side, keeps what arrives, and shows the merged result. A
    /// subscription that turns out to be a directory is replaced by the ones it lists, switched off.
    private func fetch(_ entries: [SubscriptionEntry]) async {
        let http = http
        let results = await withTaskGroup(of: (SubscriptionEntry, Result<SubscriptionImport, any Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do { return (entry, .success(try await http.subscriptionImport(WebAddress.resolve(entry.address)))) }
                    catch { return (entry, .failure(error)) }
                }
            }
            var all: [(SubscriptionEntry, Result<SubscriptionImport, any Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (entry, result) in results {
            switch result {
            case .success(.subscription(let value)): keep(value, for: entry)
            case .success(.directory(let listed)):
                guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { continue }
                let known = Set(subscriptions.map(\.address))
                subscriptions.replaceSubrange(index...index, with: listed.filter { !known.contains($0.address) })
            case .failure(let error): subscriptionErrors[entry.address] = error.localizedDescription
            }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    private func keep(_ value: Subscription, for entry: SubscriptionEntry) {
        documents[entry.address] = value
        subscriptionErrors[entry.address] = nil
        if persistsChanges, let data = try? JSONEncoder().encode(value) { try? Self.save(data, to: Self.file(for: entry)) }
    }
    private func saveSubscriptionList() {
        if persistsChanges { defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "subscriptions") }
    }
    /// Shows every enabled subscription that has a copy, merged in list order —
    /// or only the selected one when the viewer narrowed the library.
    private func rebuildSubscription(resetting: Bool = true) {
        if resetting { searchModel.reset(); recommendationModel.reset() }
        if let active = activeAddress, !subscriptions.contains(where: { $0.address == active }) {
            activeAddress = nil
            if persistsChanges { defaults.removeObject(forKey: "activeSubscriptionAddress") }
        }
        let parts: [Subscription]
        if let active = activeAddress, let solo = documents[active] { parts = [solo] }
        else { parts = subscriptions.filter(\.enabled).compactMap { documents[$0.address] } }
        subscription = Subscription.merge(parts)?.withBuiltInSites()
        if let subscription { Self.registerPlugins(subscription) }
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config)
        section = .search
    }
    func toggleFavorite(_ channel: Channel) {
        if let index = favorites.firstIndex(where: { Self.same($0, channel) }) { favorites.remove(at: index) }
        else { favorites.append(channel) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites")
    }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains { Self.same($0, channel) } }
    /// A live room's title changes while it streams, so rooms match by their address.
    private static func same(_ saved: Channel, _ channel: Channel) -> Bool {
        saved.id == channel.id || (LiveCatalog.isRoom(channel.url) && saved.url == channel.url)
    }

    func orderedSites(_ config: Subscription) -> [Site] {
        let sites = SourceStrategy.arrange(config.sites) { !$0.hidden && $0.canBrowse(jarURL: config.spiderURL) }
        return pinnedSources.arrange(sites.filter(\.isBuiltIn) + sites.filter { !$0.isBuiltIn }, origin: config.origin)
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        playbackCatalog = PlaybackCatalog(video: video, client: client.with(parses: subscription?.parseServices ?? client.parses), scope: context.id)
        return Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition)
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    func previousEpisode(before channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.previous(before: context)
    }

    /// The same episode on a transcoded line (FTY's 智 lines are the drive's own HLS) when the
    /// playing original can't play here. The same drive's line comes first: 夸父原1 → 夸父智1.
    func transcodedLine(for channel: Channel) -> Episode? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return nil }
        let current = context.episodeFlag
        let candidates = catalog.video.episodes.filter {
            $0.name == context.episodeName && $0.flag != current && $0.flag.contains("智")
        }
        let sameDrive = current.replacingOccurrences(of: "原", with: "智").replacingOccurrences(of: "无限", with: "智")
        return candidates.first { $0.flag == sameDrive } ?? candidates.first
    }

    func selectEpisode(_ episode: Episode, from channel: Channel, failed: ((String) -> Void)? = nil) {
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client)
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    /// Resumes a watched title. Choosing another title while one is still being prepared switches
    /// to it: the earlier request is cancelled, which also stops its plugin call.
    func resume(_ entry: PlaybackHistoryEntry) {
        guard resumingHistoryID != entry.id else { return }
        resumeTask?.cancel()
        resumingHistoryID = entry.id
        resumeTask = Task { await resumeHistory(entry) }
    }

    func cancelResume() {
        resumeTask?.cancel(); resumeTask = nil
        resumingHistoryID = nil
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        resumingHistoryID = entry.id
        defer { if resumingHistoryID == entry.id, !Task.isCancelled { resumingHistoryID = nil } }
        // Any enabled subscription can hold the source: it is found by its own origin and original key.
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == entry.context.origin && $0.sourceKey == entry.context.sourceKey }) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        let previousPlayback = playing
        do {
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).with(parses: config.parseServices)
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            var video = try await client.detail(entry.context.videoID, cached: site.type == 3 || site.type == 4)
            guard var episode = entry.context.episode(in: video.episodes) else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled, playing == previousPlayback, subscription?.origin == config.origin else { return }
            playing = catalogChannel(channel, video: video, episode: episode, client: client, resumePosition: entry.resumePosition)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

struct PlaybackCatalog {    let video: Video
    let client: CatalogClient
    let scope: String
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}
