import SwiftUI
import TVCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home = "Watch Now", live = "Live TV", music = "Music", search = "Global Search", sites = "Sources", favorites = "Favorites", history = "Playback History", downloads = "Downloads", settings = "Settings", more = "More"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
    /// Where Software Update lives: Settings, or More when Settings is folded into it.
    var showsUpdateBadge: Bool { self == .settings || self == .more }
    var icon: String {
        switch self {
        case .home: "play.rectangle.fill"
        case .search: "magnifyingglass"
        case .live: "dot.radiowaves.left.and.right"
        case .music: "music.note"
        case .sites: "square.grid.2x2.fill"
        case .favorites: "heart.fill"
        case .downloads: "arrow.down.circle.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        case .more: "ellipsis"
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Untyped so it can hold both More-tab sections and Route pages.
    @State private var morePath = NavigationPath()
    @State private var moreSection: AppSection = .settings
    #if os(macOS)
    /// Pushed pages in the detail column. Cleared on section change: inside NavigationSplitView the
    /// column keeps its pushed views even when the root stack's identity changes.
    @State private var detailPath = NavigationPath()
    #endif
    private var tabs: [AppSection] {
        #if os(iOS)
        if sizeClass == .compact { return [.home, .live, .music, .search, .more] }
        #endif
        return [.home, .live, .music, .search, .sites, .history, .favorites, .downloads, .settings]
    }
    var body: some View {
        @Bindable var store = store
        Group {
            #if os(macOS)
            NavigationSplitView {
                MacSidebar()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 260)
            } detail: {
                NavigationStack(path: $detailPath) { content(store.section).routeDestinations() }.id(store.section)
            }
            .onChange(of: store.section) { detailPath = NavigationPath() }
            #else
            // The system tab bar on every size class: iOS 26 floats it over content and
            // collapses extra sections into More, which a hand-built bar imitated poorly.
            platformTabs
            #endif
        }
        .onChange(of: store.section) { _, section in
            if section != .search { store.searchModel.suspend() }
        }
        // A Baidu or Aliyun line waiting for its plugin's sign-in code to be scanned.
        .sheet(item: Binding(get: { PluginSignIn.shared.prompt }, set: { if $0 == nil { PluginSignIn.shared.dismiss() } })) {
            PluginSignInView(prompt: $0)
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) { MusicPlayerScreen() }
        #endif
        // A video and a song never play over each other.
        .onChange(of: store.playing) { _, channel in if channel != nil { store.music.pause() } }
        .modifier(PlayerPresentation(playing: $store.playing))
        .updatePresentation(updates, playing: store.playing != nil)
        .alert(L10n.text("Unable to Complete"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    #if !os(macOS)
    /// Sections a phone reaches through More.
    private static let inMore: [AppSection] = [.sites, .history, .favorites, .downloads, .settings]
    private var platformTabs: some View {
        @Bindable var store = store
        return TabView(selection: $store.section) {
                ForEach(tabs) { item in
                    Tab(item.title, systemImage: item.icon, value: item) {
                        if item == .more {
                            NavigationStack(path: $morePath) {
                                content(.more).routeDestinations()
                                    .navigationDestination(for: AppSection.self) { destination in
                                        switch destination {
                                        case .sites: SitesView()
                                        case .history: PlaybackHistoryView()
                                        case .favorites: FavoritesView()
                                        case .downloads: DownloadsView()
                                        default: SettingsView()
                                        }
                                    }
                            }
                        } else { NavigationStack { content(item).tvDefaultControls().routeDestinations() } }
                    }
                    #if os(iOS)
                    // tvOS tab bars have no badges; there the launch sheet and Settings carry the news.
                    .badge(item.showsUpdateBadge && !updates.available.isEmpty ? Text(L10n.text("New")) : nil)
                    #endif
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            #if os(iOS)
            .minimizesTabBarOnScroll()
            .onChange(of: store.section) { _, section in
                if sizeClass == .compact && Self.inMore.contains(section) {
                    moreSection = section; morePath = NavigationPath([section])
                    store.section = .more
                }
            }
            .onChange(of: sizeClass) { _, size in
                if size != .compact && store.section == .more { store.section = morePath.isEmpty ? .settings : moreSection }
                else if size == .compact && Self.inMore.contains(store.section) {
                    moreSection = store.section; morePath = NavigationPath([store.section]); store.section = .more
                }
            }
            #endif
    }
    #endif


    @ViewBuilder private func content(_ section: AppSection) -> some View {
        #if DEBUG
        if QALaunch.overrides(section) { QALaunch.page(for: section, store: store) } else { sectionRoot(section) }
        #else
        sectionRoot(section)
        #endif
    }

    @ViewBuilder private func sectionRoot(_ section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        case .search: GlobalSearchView()
        case .live: LiveView()
        case .music: MusicView()
        case .sites: SitesView()
        case .favorites: FavoritesView()
        case .downloads: DownloadsView()
        case .history: PlaybackHistoryView()
        case .settings: SettingsView()
        case .more:
            List {
                NavigationLink(value: AppSection.sites) { Label(AppSection.sites.title, systemImage: AppSection.sites.icon) }
                NavigationLink(value: AppSection.history) { Label(AppSection.history.title, systemImage: AppSection.history.icon) }
                NavigationLink(value: AppSection.favorites) { Label(AppSection.favorites.title, systemImage: AppSection.favorites.icon) }
                NavigationLink(value: AppSection.downloads) { Label(AppSection.downloads.title, systemImage: AppSection.downloads.icon) }
                NavigationLink(value: AppSection.settings) { Label(AppSection.settings.title, systemImage: AppSection.settings.icon) }
                    #if os(iOS)
                    .badge(updates.available.isEmpty ? nil : Text(L10n.text("New")))
                    #endif
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .screenBackdrop()
            .screenTitle(L10n.text("More"))
        }
    }
}

private struct PlayerPresentation: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var playing: Channel?
    #if os(macOS)
    @State private var playerWindow = PlayerWindowController()
    #endif
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: playing, initial: true) { _, channel in
            if let channel {
                playerWindow.present(channel, store: store) { playing = nil }
            } else {
                playerWindow.close()
            }
        }
        #else
        content.fullScreenCover(item: $playing) { PlaybackView(channel: $0) }
        #endif
    }
}

#if os(macOS)
/// Content-first sidebar: grouped rows, neutral selection, and ⌘1–⌘8 to switch sections.
private struct MacSidebar: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    private var groups: [(title: String, items: [AppSection])] {
        [(L10n.text("Browse"), [.home, .search, .live, .music, .sites]), (L10n.text("Library"), [.history, .favorites, .downloads, .settings])]
    }

    var body: some View {
        let ordered = groups.flatMap(\.items)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            SidebarRow(section: item, selected: store.section == item,
                                       badge: item.showsUpdateBadge && !updates.available.isEmpty,
                                       shortcut: Character(String((ordered.firstIndex(of: item) ?? 0) + 1))) {
                                store.section = item
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    var badge = false
    let shortcut: Character
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge { NewBadge() }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.11 : (hovering ? 0.05 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
#endif

struct SidebarStatus: View {
    /// "Version 1.0 (1)"; nil when the bundle carries no version (e.g. MARKETING_VERSION unset).
    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        let build = info?["CFBundleVersion"] as? String ?? ""
        let text = L10n.text("Version %@", short)
        return build.isEmpty || build == short ? text : "\(text) (\(build))"
    }
    var body: some View {
        if let version {
            Text(version)
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).frame(height: 40)
                .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
                .selectable()
        }
    }
}

/// A pushed page carried as a navigation-path value. View-destination `NavigationLink`s are not
/// recorded in a stack's path, so they survive clearing it; inside NavigationSplitView that left a
/// detail page covering the newly selected sidebar section.
struct Route: Hashable, @unchecked Sendable {
    private let id = UUID()
    let build: @MainActor () -> AnyView
    static func == (lhs: Route, rhs: Route) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drop-in for `NavigationLink(destination:label:)` that pushes through the stack's path.
struct RouteLink<Label: View>: View {
    private let route: Route
    private let label: Label
    init<Destination: View>(@ViewBuilder destination: @escaping @MainActor () -> Destination, @ViewBuilder label: () -> Label) {
        route = Route { AnyView(destination()) }
        self.label = label()
    }
    var body: some View { NavigationLink(value: route) { label } }
}

extension View {
    /// Registers `Route` pages; apply once at the root of every NavigationStack.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { $0.build() }
    }
}
