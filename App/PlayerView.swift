import SwiftUI
import AVKit
import TVCore

struct PlaybackView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var session = PlaybackSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @State private var showsDanmakuList = false

    private var chromeVisible: Bool { showsChrome || session.error != nil || session.loading }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if os(tvOS)
            // Remove the native focus environment while recovery controls are shown.
            if session.error == nil {
                NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision,
                                 qualities: session.qualities, quality: session.quality, choose: { session.choose(quality: $0) },
                                 live: session.isLive, previous: episodeAction(store.previousEpisode(before: channel)),
                                 next: episodeAction(store.nextEpisode(after: channel))).ignoresSafeArea()
            }
            #else
            NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision).ignoresSafeArea()
            #endif
            #if !os(tvOS)
            chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
            #endif
            status
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaPlaybackProbe") {
                VStack {
                    Text(session.catalogDanmaku.automaticState)
                        .accessibilityIdentifier("player.qa.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                    Text("Playback position").accessibilityIdentifier("player.qa.position")
                        .accessibilityValue("\(session.position)")
                }
                .font(.caption2).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
            #endif
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 540)
        #endif
        #if !os(tvOS)
        .onContinuousHover { _ in poke() }
        .simultaneousGesture(TapGesture().onEnded { poke() })
        #endif
        .onAppear { startCatalogPlayback(session, channel: channel, store: store); poke() }
        .onChange(of: channel) { _, channel in startCatalogPlayback(session, channel: channel, store: store); poke() }
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onDisappear { hideTask?.cancel(); store.cancelEpisodeSelection(); session.stop() }
    }

    #if os(tvOS)
    private func episodeAction(_ episode: Episode?) -> EpisodeAction? {
        episode.map { episode in
            EpisodeAction(name: episode.name, busy: store.resolvingEpisode != nil) { store.selectEpisode(episode, from: channel) }
        }
    }
    #endif

    #if !os(tvOS)
    private var chrome: some View {
        VStack {
            // On a phone the title and buttons rarely fit one line: the buttons then get a row of their own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { chromeTitle; Spacer(minLength: 0); chromeButtons }
                VStack(alignment: .leading, spacing: 10) {
                    chromeTitle
                    HStack { Spacer(minLength: 0); chromeButtons }
                }
            }
            .padding(16)
            #if os(iOS)
            // Below VideoPlayer's own top row (Picture in Picture, volume), which would sit under the title.
            .padding(.top, 44)
            #endif
            Spacer()
        }
        .sheet(isPresented: $showsDanmakuList) {
            NavigationStack {
                DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                    .navigationTitle(L10n.text("Danmaku List"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsDanmakuList = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
        }
    }

    private var chromeTitle: some View {
        Text(channel.name).font(.headline).lineLimit(1)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassSurface(.regular, in: Capsule())
    }

    private var chromeButtons: some View {
        HStack(spacing: 10) {
            if let previous = store.previousEpisode(before: channel) {
                Button { store.selectEpisode(previous, from: channel) } label: {
                    Image(systemName: "backward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(store.resolvingEpisode != nil)
                .accessibilityLabel(L10n.text("Previous Episode")).help(previous.name)
            }
            if let next = store.nextEpisode(after: channel) {
                Button { store.selectEpisode(next, from: channel) } label: {
                    Image(systemName: "forward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(store.resolvingEpisode != nil)
                .accessibilityLabel(L10n.text("Next Episode")).help(next.name)
            }
            CatalogPlaybackActions(channel: channel, session: session)
            if session.qualities.count > 1 {
                Menu {
                    QualityPicker(session: session)
                } label: {
                    Image(systemName: "sparkles.tv").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Quality"))
            }
            if !session.danmaku.isEmpty {
                Button { showsDanmaku.toggle() } label: {
                    Image(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text(showsDanmaku ? "Hide Danmaku" : "Show Danmaku"))
                Button { showsDanmakuList = true } label: {
                    Image(systemName: "list.bullet.rectangle").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Danmaku List"))
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 22, height: 22) }
                .chromeButton()
                .accessibilityLabel(L10n.text("Close"))
                .accessibilityIdentifier("player.close")
                .keyboardShortcut(.cancelAction)
        }
    }

    private func poke() {
        showsChrome = true
        hideTask?.cancel()
        #if DEBUG
        // Keep screenshot/interaction QA stable while XCTest waits for AVKit to idle.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.35)) { showsChrome = false } }
        }
    }
    #else
    private func poke() {}
    #endif

    @ViewBuilder private var status: some View {
        if let error = session.error {
            #if os(tvOS)
            TVPlaybackFailureView(channelName: channel.name, details: error,
                                  retry: { startCatalogPlayback(session, channel: channel, store: store) }, goBack: { dismiss() })
            #else
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Brand.amber)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.controlButton(prominent: true).tint(Brand.accent)
                        Button(L10n.text("Close")) { dismiss() }.controlButton()
                    }
                }.controlSize(.large)
            }
            .padding(30).glassPanel(cornerRadius: 30).padding(30)
            #endif
        } else if session.loading || session.buffering {
            // Top of the frame, clear of the transport bar. Seeks stall briefly; only longer waits show.
            LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
                .padding(.horizontal, 24).padding(.top, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}

#if os(tvOS)
private struct TVPlaybackFailureView: View {
    let channelName: String
    let details: String
    let retry: () -> Void
    let goBack: () -> Void
    @State private var showsDetails = false
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            TVStyle.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: "video.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color(white: 0.65))
                    .accessibilityHidden(true)
                    .padding(.bottom, 32)
                Text(L10n.text("Playback error"))
                    .font(.system(size: 56, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 18)
                Text(channelName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(white: 0.85)).lineLimit(2)
                    .padding(.bottom, 16)
                Text(L10n.text("Try again, or go back and choose another video."))
                    .font(.system(size: 27)).foregroundStyle(Color(white: 0.65))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 20) {
                    Button(L10n.text("Retry"), action: retry).focused($retryFocused)
                    Button(L10n.text("Go back"), action: goBack)
                    Button(L10n.text(showsDetails ? "Hide details" : "Show details")) { showsDetails.toggle() }
                }
                .buttonStyle(TVPlaybackRecoveryStyle())
                .padding(.top, 48)
                if showsDetails {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 23))
                            .foregroundStyle(Color(white: 0.65))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 32)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 1120)
            .padding(64)
        }
        .onAppear { retryFocused = true }
        .onExitCommand(perform: goBack)
    }
}

private struct TVPlaybackRecoveryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RecoveryButton(configuration: configuration) }
    private struct RecoveryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .padding(.horizontal, 32).padding(.vertical, 20)
                .frame(minWidth: 220)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : TVStyle.raised, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}
#endif

#if os(macOS)
private struct NativePlayerView: View {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var body: some View {
        ZStack {
            PlayerSurface(player: player)
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision) }
        }
    }
}
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // Same AVKit scrubber trap as the window player: no native controls.
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
#elseif os(iOS)
private struct NativePlayerView: View {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var body: some View {
        // The overlay sits between the video and the playback controls.
        VideoPlayer(player: player) {
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision) }
        }
    }
}
#else
/// Full screen inside a SwiftUI view that ignores the safe area, the controller is told it has none,
/// and AVKit then lays its bottom controls into the TV's overscan margin, where focus effects are cut
/// off. This restores the title-safe area for the controls; the video and its overlays still fill the screen.
private final class TitleSafePlayerController: AVPlayerViewController {
    private static let titleSafe = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let given = view.safeAreaInsets, extra = additionalSafeAreaInsets
        let wanted = UIEdgeInsets(top: max(0, Self.titleSafe.top - (given.top - extra.top)), left: max(0, Self.titleSafe.left - (given.left - extra.left)),
                                  bottom: max(0, Self.titleSafe.bottom - (given.bottom - extra.bottom)), right: max(0, Self.titleSafe.right - (given.right - extra.right)))
        if wanted != extra { additionalSafeAreaInsets = wanted }
    }
}

struct EpisodeAction {
    let name: String
    let busy: Bool
    let play: @MainActor () -> Void
}

/// AVPlayerViewController itself, for its transport-bar menu: the Danmaku switch lives there, next to
/// subtitles and audio, where a remote can reach it. Comments draw in the content overlay, under the controls.
private struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var qualities: [StreamQuality] = []
    var quality: Int? = nil
    var choose: @MainActor (Int?) -> Void = { _ in }
    var live = false
    /// The neighbouring episodes of a catalog video, as transport-bar buttons beside the menus.
    var previous: EpisodeAction? = nil
    var next: EpisodeAction? = nil
    final class Coordinator { var host: UIHostingController<AnyView>?; var listed = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TitleSafePlayerController()
        controller.player = player
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        // Comments use the whole picture, not the TV's title-safe area.
        host.safeAreaRegions = []
        // The content overlay exists only once the controller's view has loaded.
        controller.loadViewIfNeeded()
        if let container = controller.contentOverlayView {
            controller.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                         host.view.topAnchor.constraint(equalTo: container.topAnchor), host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            host.didMove(toParent: controller)
        }
        context.coordinator.host = host
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Live has no timeline worth scrubbing: keep it at the live edge.
        if controller.requiresLinearPlayback != live { controller.requiresLinearPlayback = live }
        context.coordinator.host?.rootView = overlay
        // The comment list is a tab in the info panel (swipe down), beside the video's own info.
        if context.coordinator.listed != "\(revision):\(comments.count)" {
            context.coordinator.listed = "\(revision):\(comments.count)"
            if comments.isEmpty { controller.customInfoViewControllers = [] }
            else {
                let list = UIHostingController(rootView: DanmakuListView(player: player, comments: comments))
                list.title = L10n.text("Danmaku")
                list.preferredContentSize = CGSize(width: 0, height: 480)
                controller.customInfoViewControllers = [list]
            }
        }
        let binding = $showsDanmaku
        var items: [UIMenuElement] = []
        if !comments.isEmpty {
            items.append(UIAction(title: L10n.text("Danmaku"), image: UIImage(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble"),
                                  state: showsDanmaku ? .on : .off) { _ in binding.wrappedValue.toggle() })
        }
        if qualities.count > 1 {
            let choose = choose
            let current = qualities.first { $0.id == quality }?.label ?? L10n.text("Auto")
            let options = [UIAction(title: L10n.text("Auto"), state: quality == nil ? .on : .off) { _ in choose(nil) }]
                + qualities.map { option in UIAction(title: option.label, state: quality == option.id ? .on : .off) { _ in choose(option.id) } }
            items.append(UIMenu(title: L10n.text("Quality") + " · " + current, image: UIImage(systemName: "sparkles.tv"), children: options))
        }
        if let previous {
            items.insert(UIAction(title: L10n.text("Previous Episode"), subtitle: previous.name, image: UIImage(systemName: "backward.end.fill"),
                                  attributes: previous.busy ? [.disabled] : []) { _ in previous.play() }, at: 0)
        }
        if let next {
            items.insert(UIAction(title: L10n.text("Next Episode"), subtitle: next.name, image: UIImage(systemName: "forward.end.fill"),
                                  attributes: next.busy ? [.disabled] : []) { _ in next.play() }, at: previous == nil ? 0 : 1)
        }
        controller.transportBarCustomMenuItems = items
    }
    private var overlay: AnyView {
        AnyView(Group { if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision) } })
    }
}
#endif

#if os(macOS)
/// A real document-style window: playback remains independent of library navigation.
@MainActor final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: PlaybackWindow?
    private let session = PlaybackSession()
    private var onClose: (() -> Void)?

    func present(_ channel: Channel, store: Store, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let target: PlaybackWindow
        if let window { target = window }
        else {
            target = PlaybackWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            target.isReleasedWhenClosed = false
            target.delegate = self
            target.contentMinSize = NSSize(width: 480, height: 320)
            target.collectionBehavior = [.fullScreenPrimary]
            target.backgroundColor = .black
            target.titlebarAppearsTransparent = true
            target.titleVisibility = .hidden
            target.isMovableByWindowBackground = true
            target.center()
            target.setFrameAutosaveName("PlaybackWindow")
            target.session = session
            window = target
        }
        target.title = channel.name
        // Detach the old player view before tearing down its item: AVPlayerView's
        // timeline scrubber traps when the item is replaced while still observed
        // (EXC_BREAKPOINT in AVTimelineScrubberViewModel on macOS 27).
        target.contentView = nil
        session.stop()
        target.contentView = NSHostingView(rootView: DesktopPlaybackView(channel: channel, session: session, window: target).environment(store))
        startCatalogPlayback(session, channel: channel, store: store)
        target.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Dismantle (view.player = nil) before nil-ing the item, for the same reason.
        window?.contentView = nil
        session.stop()
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor final class PlaybackWindow: NSWindow {
    weak var session: PlaybackSession?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Preserve system commands and text/slider editing inside native controls.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(firstResponder is NSTextView), !(firstResponder is NSSlider) else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 49: session?.togglePlayback()
        case 123: session?.skip(event.modifierFlags.contains(.shift) ? -60 : -10)
        case 124: session?.skip(event.modifierFlags.contains(.shift) ? 60 : 10)
        case 126: if let player = session?.player { player.volume = min(1, player.volume + 0.05) }
        case 125: if let player = session?.player { player.volume = max(0, player.volume - 0.05) }
        case 53:
            if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
            else { return super.performKeyEquivalent(with: event) }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen(nil)
            case "m": session?.player.isMuted.toggle()
            default: return super.performKeyEquivalent(with: event)
            }
        }
        return true
    }
}

/// Auto-hiding chrome driven by real pointer movement and key presses (not hover
/// phases, which AVPlayerView's own overlay and layout passes keep re-firing).
@MainActor @Observable private final class ChromeIdle {
    var visible = true
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        detach()
        self.window = window
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                // Ignore synthetic mouse events that carry no movement.
                if event.type == .mouseMoved, abs(event.deltaX) + abs(event.deltaY) < 1 { return }
                self.poke()
            }
            return event
        }
        poke()
    }

    func detach() {
        task?.cancel(); task = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func poke() {
        if !visible { withAnimation(.smooth(duration: 0.25)) { visible = true } }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth(duration: 0.4)) { self.visible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

private struct DesktopPlaybackView: View {
    @Environment(Store.self) private var store
    let channel: Channel
    @Bindable var session: PlaybackSession
    let window: PlaybackWindow
    @State private var fillsFrame = false
    @State private var floats = false
    @State private var idle = ChromeIdle()
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @State private var showsDanmakuList = false

    private var showsChrome: Bool { idle.visible || session.error != nil }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                DesktopNativePlayer(player: session.player, fillsFrame: fillsFrame, live: session.isLive)
                if showsDanmaku && !session.danmaku.isEmpty { DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision) }
                if let error = session.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.buttonStyle(.borderedProminent)
                    }
                    .padding(24).frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
                } else if session.loading || session.buffering {
                    LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
                        .padding(.horizontal, 24).padding(.top, 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            topBar
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(showsChrome)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onChange(of: floats) { _, value in window.level = value ? .floating : .normal }
        .onChange(of: showsChrome) { _, value in setTrafficLights(visible: value) }
        .onAppear { floats = window.level == .floating; idle.attach(window) }
        .sheet(isPresented: $showsDanmakuList) {
            VStack(spacing: 0) {
                DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                HStack { Spacer(); Button(L10n.text("Done")) { showsDanmakuList = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(width: 520, height: 600)
        }
        .onDisappear { idle.detach() }
    }

    /// Title on the left (beside the traffic lights), actions on the right, over a soft scrim.
    private var topBar: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(.leading, 86)
            Spacer(minLength: 12)
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if session.isLive {
                        // Live hides AVKit's controls (see DesktopNativePlayer), so play and mute live here.
                        barButton(session.paused ? "play.fill" : "pause.fill", L10n.text("Play / Pause (Space)")) { session.togglePlayback() }
                        barButton(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", L10n.text("Mute (M)")) { session.player.isMuted.toggle() }
                    } else {
                        barButton("gobackward.10", L10n.text("Back 10 seconds (←)")) { session.skip(-10) }
                        barButton("goforward.10", L10n.text("Forward 10 seconds (→)")) { session.skip(10) }
                    }
                    CatalogPlaybackActions(channel: channel, session: session)
                    optionsMenu
                    barButton("arrow.up.left.and.arrow.down.right", L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
                }
            }
        }
        .padding(.top, 10).padding(.trailing, 16).padding(.bottom, 36)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
            .glassSurface(.regular.interactive(), in: Circle())
            .help(label)
            .accessibilityLabel(label)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(L10n.text("Loop Playback"), isOn: $session.looping)
            Toggle(L10n.text("Fill Window"), isOn: $fillsFrame)
            Toggle(L10n.text("Float on Top"), isOn: $floats)
            if session.qualities.count > 1 {
                Menu(L10n.text("Quality")) { QualityPicker(session: session) }
            }
            if !session.danmaku.isEmpty {
                Toggle(L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                Button(L10n.text("Danmaku List…")) { showsDanmakuList = true }
            }
            Divider()
            Button(L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
            Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }
            Divider()
            Text(L10n.text("Space: Play / Pause"))
            Text(L10n.text("← / →: Seek 10s · Shift: 60s"))
            Text(L10n.text("↑ / ↓: Volume · M: Mute · F: Full Screen"))
        } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 34, height: 34)
            .glassSurface(.regular.interactive(), in: Circle())
            .help(L10n.text("Playback Options"))
            .accessibilityLabel(L10n.text("Playback Options"))
    }

    private func setTrafficLights(visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// AVPlayerView without its controls for live streams. Its floating controls build a scrubber from the
/// item's duration and seekable range; a live item has an indefinite duration and, at first, no
/// seekable range, and AVKit traps on that range (macOS 27). tvOS avoids it with linear playback.
private struct DesktopNativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    var live = false
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // AVPlayerView's timeline scrubber (floating AND inline) traps in
        // AVTimelineScrubberViewModel's Binding to _currentTime on macOS 27
        // (EXC_BREAKPOINT). .none creates no scrubber; play/mute live in topBar.
        view.controlsStyle = .none
        view.player = player
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.showsSharingServiceButton = false
        view.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×") }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.controlsStyle != .none { view.controlsStyle = .none }
        if view.player !== player { view.player = player }
        view.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
#endif

#if !os(tvOS)
/// Automatic, or one of the stream's qualities, best first.
private struct QualityPicker: View {
    let session: PlaybackSession
    var body: some View {
        Picker(L10n.text("Quality"), selection: Binding(get: { session.quality ?? 0 }, set: { session.choose(quality: $0 == 0 ? nil : $0) })) {
            Text(L10n.text("Auto")).tag(0)
            ForEach(session.qualities) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.inline)
    }
}
#endif

/// Shared setup leaves the native AVKit controls and Bilibili resolution intact.
@MainActor private func startCatalogPlayback(_ session: PlaybackSession, channel: Channel, store: Store) {
    session.history = store.playbackHistory
    session.skipDefaults = store.playbackDefaults
    session.catalogDanmaku.enabled = UserDefaults.standard.object(forKey: DanmakuPreference.key) == nil
        || UserDefaults.standard.bool(forKey: DanmakuPreference.key)
    session.start(channel)
    session.onPlaybackEnded = { [weak store] in
        guard let store, store.autoPlayNext, let next = store.nextEpisode(after: channel) else { return }
        store.selectEpisode(next, from: channel)
    }
    if let context = channel.historyContext, let next = store.nextEpisode(after: channel),
       let catalog = store.catalog(for: channel), context.sourceKey != Bilibili.siteKey {
        session.catalogDanmaku.prefetch(PlaybackHistoryContext(origin: context.origin, site: catalog.client.site,
            video: catalog.video, episode: next))
    }
}
