import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    let searchModel = SearchModel()
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    var resumingHistoryID: String?
    /// Every imported subscription, kept side by side. Importing a new URL appends
    /// (or refreshes the entry with the same address) instead of replacing the others.
    var entries: [SavedSubscription] = []
    var activeID: UUID?
    /// The selected subscription's content. Views keep reading this; switching entries swaps it.
    var subscription: Subscription?
    var subscriptionAddress: String
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
        subscriptionAddress = defaults.string(forKey: "subscriptionAddress") ?? Self.defaultURL
        if persistsChanges, let legacy = defaults.data(forKey: "subscription") {
            // Older builds kept the whole subscription in defaults; move it into the entries once.
            migrateDefaultsLegacy(legacy)
            defaults.removeObject(forKey: "subscription")
        }
        loadEntries()
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
                ?? (item.source.siteKey == Site.bilibili.key ? Site.bilibili : nil) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so this download can't continue.", item.source.siteName))
        }
        let client = CatalogClient(site: site, origin: config?.origin ?? URL(string: "https://example.invalid/")!, jarURL: config?.spiderURL)
            .with(parses: config?.parseServices ?? [])
        let plan = try await client.preparePlayback(item.source.episode)
        return try await client.resolvePlayback(plan, choice: plan.choices[0])
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in its own file and only the index stays in defaults.
    /// tvOS only offers Caches, which the system may purge; `restoreSubscription()` refetches
    /// the selected entry when its file is gone.
    private static var storeDirectory: URL {
        #if os(tvOS)
        URL.cachesDirectory
        #else
        URL.applicationSupportDirectory
        #endif
    }
    private static var indexFile: URL { storeDirectory.appending(path: "subscriptions.json") }
    private static func dataFile(id: UUID) -> URL { storeDirectory.appending(path: "subscription-\(id.uuidString).json") }
    private static var legacyFile: URL { storeDirectory.appending(path: "subscription.json") }
    private static func saveData(_ data: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try data.write(to: dataFile(id: id), options: .atomic)
    }

    /// Older builds kept the whole subscription in defaults; move it into the entries once.
    private func migrateDefaultsLegacy(_ legacy: Data) {
        guard (try? Data(contentsOf: Self.indexFile)) == nil,
              let value = try? JSONDecoder().decode(Subscription.self, from: legacy) else { return }
        let entry = SavedSubscription(id: UUID(), address: defaults.string(forKey: "subscriptionAddress") ?? value.origin.absoluteString,
                                      displayName: Self.displayName(for: value.origin),
                                      siteCount: value.sites.count, liveCount: value.lives.count, importedAt: value.importedAt)
        try? Self.saveData(legacy, id: entry.id)
        try? Self.saveIndex([entry])
    }

    /// Loads the index and the selected entry; migrates the pre-list single file once.
    private func loadEntries() {
        if persistsChanges, let legacy = try? Data(contentsOf: Self.legacyFile),
           (try? Data(contentsOf: Self.indexFile)) == nil {
            let id = UUID()
            if let value = try? JSONDecoder().decode(Subscription.self, from: legacy) {
                let entry = SavedSubscription(id: id, address: defaults.string(forKey: "subscriptionAddress") ?? value.origin.absoluteString,
                                              displayName: Self.displayName(for: value.origin),
                                              siteCount: value.sites.count, liveCount: value.lives.count, importedAt: value.importedAt)
                try? Self.saveData(legacy, id: id)
                try? Self.saveIndex([entry])
            }
            try? FileManager.default.removeItem(at: Self.legacyFile)
        }
        entries = (try? Data(contentsOf: Self.indexFile)).flatMap { try? JSONDecoder().decode([SavedSubscription].self, from: $0) } ?? []
        if let saved = defaults.string(forKey: "activeSubscriptionID"), let id = UUID(uuidString: saved),
           entries.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = entries.first?.id
        }
        activateCurrent()
    }

    private static func saveIndex(_ entries: [SavedSubscription]) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: indexFile, options: .atomic)
    }

    private static func displayName(for url: URL) -> String { url.host() ?? url.absoluteString }

    /// Decodes the selected entry and publishes it as `subscription`.
    private func activateCurrent() {
        guard let id = activeID, entries.contains(where: { $0.id == id }),
              let data = try? Data(contentsOf: Self.dataFile(id: id)),
              let value = try? JSONDecoder().decode(Subscription.self, from: data) else {
            if activeID != nil, entries.isEmpty { activeID = nil }
            subscription = nil
            return
        }
        subscription = value.withBuiltInSites()
        Self.registerPlugins(value)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches the selected subscription whose cached file is gone.
    func restoreSubscription() async {
        guard subscription == nil, let id = activeID,
              entries.contains(where: { $0.id == id }) else { return }
        await importSubscription()
    }
    /// Imports a URL as its own entry: a new address appends, a known address refreshes
    /// in place. Other entries are never touched, so the first subscription survives the second.
    func importSubscription(address: String? = nil) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        do {
            let url = try WebAddress.resolve(address ?? subscriptionAddress)
            let value = try await http.subscription(url)
            // Resolve the entry first so the data file and the index share one id.
            let id = Self.entryID(for: url, origin: value.origin, in: entries) ?? UUID()
            if persistsChanges { try Self.saveData(JSONEncoder().encode(value), id: id) }
            upsertEntry(id: id, address: url.absoluteString, value: value)
            subscriptionAddress = url.absoluteString
            searchModel.reset()
            recommendationModel.reset()
            subscription = value.withBuiltInSites()
            Self.registerPlugins(value)
            notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
        } catch { self.error = L10n.text("Import failed: %@", error.localizedDescription) }
    }

    /// Switches the visible library to another imported subscription.
    func selectSubscription(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id
        if persistsChanges { defaults.set(id.uuidString, forKey: "activeSubscriptionID") }
        searchModel.reset()
        recommendationModel.reset()
        activateCurrent()
    }

    /// Re-imports one entry's address without touching the others.
    func refreshSubscription(_ id: UUID) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let previous = subscriptionAddress
        subscriptionAddress = entry.address
        await importSubscription(address: entry.address)
        subscriptionAddress = previous
    }

    /// Forgets one subscription; the others stay. Selecting a neighbour keeps a library on screen.
    func removeSubscription(_ id: UUID) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.dataFile(id: id))
        if persistsChanges { try? Self.saveIndex(entries) }
        if activeID == id {
            activeID = entries.first?.id
            if persistsChanges {
                if let activeID { defaults.set(activeID.uuidString, forKey: "activeSubscriptionID") }
                else { defaults.removeObject(forKey: "activeSubscriptionID") }
            }
            searchModel.reset()
            recommendationModel.reset()
            activateCurrent()
        }
    }

    /// The entry a URL belongs to, matched by canonical address or response origin,
    /// so re-imports refresh in place.
    private static func entryID(for url: URL, origin: URL, in entries: [SavedSubscription]) -> UUID? {
        entries.first { $0.address == url.absoluteString || $0.address == origin.absoluteString }?.id
    }

    private func upsertEntry(id: UUID, address: String, value: Subscription) {
        let entry = SavedSubscription(id: id, address: address, displayName: Self.displayName(for: value.origin),
                                      siteCount: value.sites.count, liveCount: value.lives.count, importedAt: value.importedAt)
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
        else { entries.append(entry) }
        setActive(id)
        if persistsChanges { try? Self.saveIndex(entries) }
    }

    private func setActive(_ id: UUID) {
        activeID = id
        if persistsChanges { defaults.set(id.uuidString, forKey: "activeSubscriptionID") }
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
        if let index = favorites.firstIndex(where: { $0.id == channel.id }) { favorites.remove(at: index) }
        else { favorites.append(channel) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites")
    }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains { $0.id == channel.id } }

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

    func selectEpisode(_ episode: Episode, from channel: Channel) {
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
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        guard resumingHistoryID == nil else { return }
        guard let config = subscription, config.origin == entry.context.origin,
              let site = config.sites.first(where: { $0.key == entry.context.sourceKey }) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        resumingHistoryID = entry.id
        let previousPlayback = playing
        defer { resumingHistoryID = nil }
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
            guard !(error is CancellationError) else { return }
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

/// One imported subscription in the side-by-side list. The parsed content lives in
/// its own data file; the index only carries what lists need to display.
struct SavedSubscription: Codable, Identifiable, Sendable {
    var id: UUID
    var address: String
    var displayName: String
    var siteCount: Int
    var liveCount: Int
    var importedAt: Date
}

struct PlaybackCatalog {    let video: Video
    let client: CatalogClient
    let scope: String
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}
