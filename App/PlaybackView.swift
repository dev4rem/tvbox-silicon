import SwiftUI
import AVKit
import TVCore

@MainActor @Observable final class PlaybackSession {
    let player = AVPlayer()
    let catalogDanmaku = CatalogDanmakuModel()
    var history = PlaybackHistory.shared
    var skipDefaults = UserDefaults.standard
    private var historyContext: PlaybackHistoryContext?
    private var pendingResume: Double?
    private var restoringPosition = false
    private(set) var restoredPosition: Double?
    private(set) var requestedResumePosition: Double?
    private(set) var skipSettings = EpisodeSkipSettings()
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private var skipScope: String?
    private var skipPass = EpisodeSkipPass()
    private var editingSkip = false
    private var resumeAfterEditing = false
    private var seekingSegment = false

    func beginEditingSkip() {
        editingSkip = true
        resumeAfterEditing = player.rate > 0
        player.pause()
    }

    func endEditingSkip() {
        editingSkip = false
        if resumeAfterEditing { player.play() }
        resumeAfterEditing = false
    }

    func applySkipSettings(_ settings: EpisodeSkipSettings) {
        guard let skipScope else { return }
        settings.save(scope: skipScope, defaults: skipDefaults)
        skipSettings = settings
        skipPass = EpisodeSkipPass()
    }

    private func updateSkipping(_ item: AVPlayerItem) {
        let time = player.currentTime().seconds
        position = time.isFinite ? max(0, time) : 0
        let length = item.duration.seconds
        duration = length.isFinite ? max(0, length) : 0
        guard skipScope != nil, !editingSkip, !seekingSegment, pendingResume == nil, !restoringPosition,
              item.status == .readyToPlay else { return }
        var pass = skipPass
        guard let target = pass.target(time: time, duration: length, playing: player.rate > 0, settings: skipSettings) else {
            skipPass = pass
            return
        }
        guard item.seekableTimeRanges.contains(where: { CMTimeRangeContainsTime($0.timeRangeValue, time: CMTime(seconds: target, preferredTimescale: 600)) }) else { return }
        skipPass = pass
        seekingSegment = true
        let activeGeneration = generation
        Diagnostics.shared.record(.info, "player", "skip segment from=\(Int(time)) to=\(Int(target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.seekingSegment = false
            }
        }
    }

    var error: String?
    var loading = true
    var looping = false
    var buffering = false
    /// Bullet comments for the media, when its source has them.
    private var sourceDanmaku: [Danmaku] = []
    var danmaku: [Danmaku] { sourceDanmaku.isEmpty ? catalogDanmaku.renderedComments : sourceDanmaku }
    var danmakuOpacity: Double { sourceDanmaku.isEmpty ? catalogDanmaku.opacity : 0.9 }
    var danmakuRevision: String { sourceDanmaku.isEmpty ? catalogDanmaku.renderedRevision : "" }
    var onPlaybackEnded: (() -> Void)?
    /// Plays another line of the same episode when this file can't play here (an MKV original);
    /// returns that line's name, or nil when there is none.
    var onUnplayableFile: (() -> String?)?
    /// Why the player is switching lines, shown while the other line loads.
    private var switchNotice: String?
    /// Qualities the stream can switch between (Bilibili), and the one chosen; nil is automatic.
    private(set) var qualities: [StreamQuality] = []
    /// A live stream: played at the live edge, without scrubbing.
    private(set) var isLive = false
    /// Mirrors the player, for play and mute buttons drawn outside AVKit's controls.
    private(set) var paused = false
    private(set) var muted = false
    private(set) var quality: Int?
    private var playing: Channel?
    private var automatic: URL?
    /// A live room's chat, whose comments join `danmaku` as they are sent.
    private var chat: BilibiliLiveChat?
    /// Download state while connecting or buffering, sampled once a second from AVFoundation's logs.
    struct Transfer {
        var received: Int64 = 0
        /// Over the last few seconds; nil until two samples exist.
        var bytesPerSecond: Double?
        /// What the playing variant needs to play without stalling.
        var required: Double?
        var host: String?
        /// The latest failure while loading media: an HTTP status, or a network error description.
        var failure: String?
        var httpStatus: Int?
    }
    private(set) var transfer = Transfer()
    private var sampler: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?

    func togglePlayback() {
        if player.timeControlStatus == .paused {
            if let item = player.currentItem, item.duration.seconds.isFinite,
               player.currentTime().seconds >= item.duration.seconds - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        } else { player.pause() }
    }

    func skip(_ seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard let range = ranges.first(where: { CMTimeRangeContainsTime($0, time: player.currentTime()) }) ?? ranges.last else { return }
        let target = min(max(current + seconds, range.start.seconds), range.end.seconds)
        guard target.isFinite else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Shows a live room's chat as danmaku: each comment enters as it arrives.
    private func listen(room: Int, generation active: UUID) {
        let chat = BilibiliLiveChat(room: room)
        self.chat = chat
        chat.start { text, color, position in
            Task { @MainActor [weak self] in
                guard let self, self.generation == active else { return }
                let now = self.player.currentTime().seconds
                let time = max(now.isFinite ? now + 0.2 : 0, self.sourceDanmaku.last?.time ?? 0)
                self.sourceDanmaku.append(Danmaku(time: time, position: position, color: color, text: text))
                // Keep the recent chat; dropping the oldest restarts the overlay's layout once.
                if self.sourceDanmaku.count > 4000 { self.sourceDanmaku.removeFirst(1000) }
            }
        }
    }

    /// Plays the stream at `quality` (nil: automatic) from where it is now.
    func choose(quality: Int?) {
        guard let channel = playing, quality != self.quality,
              let url = quality.flatMap({ id in qualities.first { $0.id == id }?.url }) ?? automatic else { return }
        if LiveCatalog.isRoom(url) {
            // A live quality is another stream address, fetched now; live has no position to keep.
            let active = generation
            Task {
                guard let resolved = try? await LiveCatalog.resolve(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo)),
                      self.generation == active else { return }
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
                if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
                self.endObserver = nil; self.failureObserver = nil
                self.sampler?.cancel(); self.sampler = nil
                self.quality = resolved.current ?? quality
                self.configure(resolved.channel, url: resolved.channel.url, generation: active)
            }
            return
        }
        let time = player.currentTime(), paused = player.rate == 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
        sampler?.cancel(); sampler = nil
        self.quality = quality
        configure(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers), url: url, generation: generation)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if paused { player.pause() }
    }

    /// The other line could not be resolved either: show why instead of loading forever.
    func lineSwitchFailed(_ message: String) {
        guard switchNotice != nil else { return }
        switchNotice = nil; error = message; loading = false
    }

    func setSpeed(_ speed: Float) {
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }
    private var generation = UUID()
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    #if os(macOS)
    private var proxy: HLSProxy?
    #endif
    /// The session on screen, which casts from the Bilibili app control.
    static weak var current: PlaybackSession?
    func start(_ channel: Channel) {
        Self.current = self
        stop(); error = nil; loading = true; sourceDanmaku = []; qualities = []; quality = nil; switchNotice = nil
        historyContext = channel.historyContext
        requestedResumePosition = channel.resumePosition
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        skipScope = channel.skipScope
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        if !DanmakuSource.has(channel.url), channel.historyContext?.sourceKey != Bilibili.siteKey {
            catalogDanmaku.startAutomatic(channel.historyContext)
        }
        isLive = LiveCatalog.isRoom(channel.url) || channel.group == L10n.text("Bilibili Live")
        let activeGeneration = generation
        Diagnostics.shared.record(.info, "player", "start name=\(channel.name) group=\(channel.group) url=\(channel.url.absoluteString) headers=\(channel.headers.keys.sorted().joined(separator: ","))")
        preparation = Task { [weak self] in
            guard let self else { return }
            // A live room becomes its current stream address now; the address expires.
            var channel = channel
            var liveQualities: [StreamQuality] = [], liveQuality: Int?
            if let room = BilibiliLive.room(channel.url) { self.listen(room: room, generation: activeGeneration) }
            if LiveCatalog.isRoom(channel.url) {
                do { (channel, liveQualities, liveQuality) = try await LiveCatalog.resolve(channel) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; self.loading = false; return
                }
            }
            var address = channel.url
            do { address = try await EmbeddedJarHost.shared.recoverProxy(address) }
            catch {
                guard self.generation == activeGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false; return
            }
            // A cloud-drive file streams straight from its CDN: the plugin's proxy only reveals the
            // address. Otherwise every range AVPlayer opens costs the plugin a set of threads.
            if let media = await EmbeddedJarHost.shared.directMedia(address) {
                guard self.generation == activeGeneration, !Task.isCancelled else { return }
                let proxied = address
                address = CloudStreams.register(media) { await EmbeddedJarHost.shared.directMedia(proxied) }
                Diagnostics.shared.record(.info, "player", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
                // Drives keep originals as uploaded; Apple devices can't open MKV. Say so now, or switch
                // to the drive's transcoded line, instead of letting AVPlayer fail with a vague error.
                if await CloudStreams.isMatroska(address) {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    if let line = self.onUnplayableFile?() {
                        Diagnostics.shared.record(.warning, "player", "mkv original; switching to line=\(line)")
                        self.switchNotice = L10n.text("The original file is MKV, which Apple devices can't play, so the %@ line is playing instead.", line)
                        return
                    }
                    Diagnostics.shared.record(.warning, "player", "mkv original; no transcoded line")
                    self.error = L10n.text("This video is an MKV file, which Apple devices can't play."); self.loading = false; return
                }
            } else if EmbeddedJarHost.isPluginProxy(address) {
                // Every byte of this stream passes through the plugin runtime.
                Diagnostics.shared.record(.warning, "player", "plugin proxy stream \(EmbeddedJarHost.proxyRoute(address))")
            }
            // A downloaded episode plays from disk: its file, or its HLS through a loopback server.
            if address.scheme == DownloadLibrary.scheme {
                do { address = try await DownloadLibrary.shared.playbackAddress(for: address) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; self.loading = false; return
                }
            }
            #if os(macOS)
            if address.pathExtension.lowercased() == "m3u8", address.scheme != BilibiliStreams.scheme, channel.url.scheme != DownloadLibrary.scheme {
                let adapter = HLSProxy(headers: channel.headers)
                self.proxy = adapter
                do { address = try await adapter.start(url: address) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    Diagnostics.shared.record(.error, "player", "proxy failed host=\(channel.url.host() ?? "-") \(Self.describe(error))")
                    self.error = error.localizedDescription; self.loading = false; return
                }
            }
            #endif
            guard self.generation == activeGeneration, !Task.isCancelled else { return }
            self.configure(channel, url: address, generation: activeGeneration)
            self.playing = channel; self.automatic = address
            self.qualities = liveQualities.isEmpty ? BilibiliStreams.qualities(for: address) : liveQualities
            self.quality = liveQuality
            if DanmakuSource.has(channel.url), let comments = await DanmakuSource.comments(for: channel.url),
               self.generation == activeGeneration { self.sourceDanmaku = comments }
        }
    }
    private func configure(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = error.localizedDescription }
        #endif
        // Some providers require request headers. AVURLAsset's HTTP-header option is
        // best-effort and is not a guarantee for every redirected HLS segment.
        let asset = CloudStreams.asset(for: url) ?? HongguoStreams.asset(for: url) ?? BilibiliStreams.asset(for: url)
            ?? AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        let item = AVPlayerItem(asset: asset)
        if url.scheme == HongguoStreams.scheme { item.preferredForwardBufferDuration = HongguoStreams.forwardBufferDuration }
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            let detail = item.error.map(Self.describe) ?? "-"
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                if status == .readyToPlay {
                    self.restorePositionIfNeeded(item)
                    self.loading = self.pendingResume != nil || self.restoringPosition
                    Diagnostics.shared.record(.info, "player", "ready host=\(self.transfer.host ?? channel.url.host() ?? "-")")
                }
                if status == .failed {
                    self.loading = false; self.error = message ?? L10n.text("This media cannot be played. Try another channel or source.")
                    Diagnostics.shared.record(.error, "player", "failed host=\(self.transfer.host ?? channel.url.host() ?? "-") \(self.transfer.failure.map { "upstream=\($0) " } ?? "")\(detail)")
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = failure?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                Diagnostics.shared.record(.error, "player", "interrupted host=\(self.transfer.host ?? channel.url.host() ?? "-") at=\(Int(self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : -1))s \(failure.map(Self.describe) ?? "-")")
                self.error = message ?? L10n.text("Playback was interrupted."); self.loading = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.saveHistory(completed: true)
                if self.looping {
                    self.skipPass = EpisodeSkipPass()
                    self.player.seek(to: .zero); self.player.play()
                } else { self.onPlaybackEnded?() }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let paused = player.timeControlStatus == .paused
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.buffering = waiting
                self.paused = paused
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.initial, .new]) { [weak self] player, _ in
            let muted = player.isMuted
            Task { @MainActor [weak self] in self?.muted = muted }
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.replaceCurrentItem(with: item)
        if pendingResume == nil { player.play() }
        #if DEBUG
        // `-qaSeek <seconds>` starts playback there, for screenshots.
        let qaSeek = UserDefaults.standard.double(forKey: "qaSeek")
        if qaSeek > 0 { player.seek(to: CMTime(seconds: qaSeek, preferredTimescale: 600)) }
        #endif
        let origin = channel.url.host()
        sampler = Task { [weak self] in
            var history: [(date: Date, bytes: Int64)] = []
            var tick = 0
            while !Task.isCancelled {
                guard self?.sample(&history, tick: tick, origin: origin, generation: activeGeneration) == true else { return }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func sample(_ history: inout [(date: Date, bytes: Int64)], tick: Int, origin: String?, generation activeGeneration: UUID) -> Bool {
        guard generation == activeGeneration else { return false }
        guard let item = player.currentItem else { return true }
        restorePositionIfNeeded(item)
        updateSkipping(item)
        if let url = playing?.url { HongguoStreams.updatePosition(for: url, seconds: pendingResume ?? player.currentTime().seconds) }
        if tick % 5 == 0 { saveHistory() }
        let events = item.accessLog()?.events ?? []
        let now = Date()
        var next = Transfer(received: events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) })
        // A resource-loader stream's bytes never reach the access log.
        let cloud = automatic.flatMap(CloudStreams.transfer(for:))
        if let cloud { next.received = max(next.received, cloud.received) }
        #if os(macOS)
        // HLS goes through the local proxy, which sees upstream bytes as they arrive.
        let upstream = proxy?.stats.snapshot
        if let upstream { next.received = max(next.received, upstream.received) }
        #endif
        history.append((now, next.received))
        history.removeAll { now.timeIntervalSince($0.date) > 5 }
        if let first = history.first, now.timeIntervalSince(first.date) >= 1 {
            next.bytesPerSecond = Double(next.received - first.bytes) / now.timeIntervalSince(first.date)
        }
        // Prefer the decoded media's own bitrate; single-variant playlists declare none. AVFoundation's
        // average counts a half-fetched segment's bytes against finished durations, so it runs high
        // mid-segment and settles at each boundary: keep the lowest value seen.
        if let last = events.last {
            let media = max(0, last.averageVideoBitrate) + max(0, last.averageAudioBitrate)
            let current = media > 0 ? media / 8 : (last.indicatedBitrate > 0 ? last.indicatedBitrate / 8 : nil)
            next.required = [current, transfer.required].compactMap { $0 }.min()
        }
        // The Mac plays HLS through a local proxy; name the real server instead.
        let segmentHost = events.last?.uri.flatMap { URL(string: $0)?.host() }
        next.host = segmentHost.flatMap { ["127.0.0.1", "localhost"].contains($0) ? nil : $0 } ?? cloud?.host ?? origin
        #if os(macOS)
        if let upstream {
            next.host = upstream.host ?? next.host
            next.httpStatus = upstream.status.flatMap { (400..<600).contains($0) ? $0 : nil }
            next.failure = upstream.failure ?? upstream.status.map { "HTTP \($0)" }
        }
        #endif
        if next.failure == nil, let error = item.errorLog()?.events.last, let date = error.date, now.timeIntervalSince(date) < 30 {
            if (400..<600).contains(error.errorStatusCode) { next.httpStatus = error.errorStatusCode }
            next.failure = error.errorComment ?? "\(error.errorDomain) \(error.errorStatusCode)"
        }
        transfer = next
        #if DEBUG
        if QALaunch.page?.hasPrefix("play-source:") == true || QALaunch.page == "resume-last" {
            let report: [String: Any] = ["seconds": position, "duration": duration, "ready": item.status == .readyToPlay,
                "rate": player.rate, "error": error ?? "", "danmakuCount": danmaku.count,
                "errorDetail": item.error.map(Self.describe) ?? "", "videoWidth": item.presentationSize.width, "videoHeight": item.presentationSize.height,
                "danmakuState": catalogDanmaku.automaticState, "cached": catalogDanmaku.fromCache,
                "introEnd": skipSettings.introEnd, "outroLength": skipSettings.outroLength,
                "requestedResumePosition": requestedResumePosition ?? 0, "restoredPosition": restoredPosition ?? 0]
            try? JSONSerialization.data(withJSONObject: report).write(to: URL.cachesDirectory.appending(path: "qa-playback.json"), options: .atomic)
        }
        #endif
        if (loading || buffering) && tick % 5 == 0 {
            Diagnostics.shared.record(.debug, "player", "waiting host=\(next.host ?? "-") received=\(next.received) speed=\(Int(next.bytesPerSecond ?? -1)) required=\(Int(next.required ?? -1)) failure=\(next.failure ?? "-")")
        }
        return true
    }
    /// Domain and code of the error and its underlying cause: AVFoundation's messages alone
    /// ("The operation could not be completed") don't tell an HTTP 403 from a decoder failure.
    nonisolated static func describe(_ error: Error) -> String {
        let error = error as NSError
        var text = "error=\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " underlying=\(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
        }
        return text
    }
    func stop() {
        saveHistory()
        if let url = playing?.url { HongguoStreams.stop(url) }
        if let automatic { CloudStreams.stop(automatic) }
        playing = nil
        catalogDanmaku.clear()
        historyContext = nil; pendingResume = nil; restoringPosition = false
        requestedResumePosition = nil; restoredPosition = nil
        skipScope = nil; skipSettings = EpisodeSkipSettings(); skipPass = EpisodeSkipPass()
        position = 0; duration = 0; editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        onPlaybackEnded = nil; onUnplayableFile = nil
        if player.currentItem != nil {
            let seconds = player.currentTime().seconds
            Diagnostics.shared.record(.info, "player", "stop at=\(seconds.isFinite ? Int(seconds) : -1)s")
        }
        generation = UUID()
        chat?.stop(); chat = nil
        preparation?.cancel(); preparation = nil
        sampler?.cancel(); sampler = nil
        transfer = Transfer()
        #if os(macOS)
        if let proxy { Task { await proxy.stop() } }; proxy = nil
        #endif
        observation = nil
        timeObservation = nil
        muteObservation = nil
        buffering = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause(); player.replaceCurrentItem(with: nil)
    }
    func saveHistory(completed: Bool = false) {
        guard let context = historyContext, let item = player.currentItem, item.status == .readyToPlay,
              pendingResume == nil, !restoringPosition, !seekingSegment else { return }
        let length = item.duration.seconds
        let time = completed && length.isFinite ? length : player.currentTime().seconds
        history.record(context, position: time, duration: length.isFinite ? length : 0)
    }

    private func restorePositionIfNeeded(_ item: AVPlayerItem) {
        guard let requested = pendingResume, !restoringPosition, item.status == .readyToPlay,
              let target = PlaybackHistoryEntry.resumeTarget(requested, duration: item.duration.seconds) else { return }
        restoringPosition = true
        let activeGeneration = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.restoringPosition = false; self.pendingResume = nil; self.loading = false
                guard finished else {
                    self.error = L10n.text("The player could not restore the saved position. Try again.")
                    return
                }
                self.restoredPosition = self.player.currentTime().seconds
                Diagnostics.shared.record(.info, "player", "history resume requested=\(requested) restored=\(self.restoredPosition ?? -1)")
                if !self.editingSkip { self.player.play() }
                self.saveHistory()
            }
        }
    }
}

extension PlaybackSession {
    /// The player's wait, with download speed against what the video needs.
    var loadingProgress: LoadingProgress {
        let transfer = transfer
        // AVPlayer counts the first segment only once it finishes, so zero bytes means "not yet", not "stalled".
        let speed = transfer.received > 0 ? transfer.bytesPerSecond.map(Self.rate) : nil
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        if let switchNotice {
            progress.reason = switchNotice
            return progress
        }
        if let speed {
            progress.detail = transfer.required.map { L10n.text("%@ · needs %@", speed, Self.rate($0)) }
                ?? L10n.text("Downloading at %@", speed)
        } else if let host = transfer.host {
            progress.detail = L10n.text("Waiting for %@", host)
        }
        let server = transfer.host ?? L10n.text("The video server")
        if let status = transfer.httpStatus {
            progress.reason = L10n.text("%@ returned an error (%@). The link may have expired: go back and play the episode again, or choose another line.", server, "HTTP \(status)")
        } else if let failure = transfer.failure {
            progress.reason = L10n.text("Couldn't load video from %@ (%@). Check the connection, or choose another line.", server, failure)
        } else if transfer.received == 0 {
            progress.reason = L10n.text("%@ hasn't delivered the first part of the video yet. The server may be slow or down; try another line.", server)
        } else if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
            progress.reason = L10n.text("%@ sends %@, but this video needs about %@. Try another line, or wait without skipping.", server, Self.rate(bytes), Self.rate(required))
        } else {
            progress.reason = L10n.text("The player is filling its buffer before playback continues.")
        }
        return progress
    }
    private static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return L10n.text("%@/s", formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))
    }
}
