import SwiftUI
import TVCore

// MARK: Settings building blocks
// The pages under Settings are built from these, so they match the Settings page itself: the
// system's grouped form on iPhone, iPad and Mac, and on Apple TV a page like the TV's own Settings
// subpages, with a symbol and title on the left and sections of rows on the right.

/// A titled run of rows with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSection(title: title, footer: footer) { content }
        #else
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
        #endif
    }
}

/// Icon tile, title, optional subtitle and a trailing accessory. On Apple TV the row goes without
/// the tile, as rows do in the TV's own Settings.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 29, weight: .medium)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 32)
            trailing
        }
        // The insets of a `glassRow()`, so static rows line up with the rows that can be selected.
        .padding(.horizontal, 28).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        #else
        LabeledContent { trailing } label: { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A row that opens a subpage.
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        #if os(tvOS)
        TVSettingsLink(title: title, value: subtitle, destination: destination)
        #else
        RouteLink(destination: destination) { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

/// A row that does something in place, such as clearing the cache: the whole row is the button.
struct SettingsActionRow: View {
    let title: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        #if os(tvOS)
        TVSettingsAction(title: title, destructive: destructive, action: action)
        #else
        Button(title, role: destructive ? .destructive : nil, action: action).formRowButton()
        #endif
    }
}

extension View {
    /// Buttons inside settings rows: the TV's control style, and the system's bordered buttons in
    /// the system accent elsewhere, as in System Settings and the Settings app.
    @ViewBuilder func settingsButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        controlButton(prominent: prominent)
        #elseif os(iOS)
        if prominent { buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(systemAccent) }
        else { buttonStyle(.bordered).buttonBorderShape(.capsule).tint(systemAccent) }
        #else
        if prominent { buttonStyle(.borderedProminent).tint(systemAccent) } else { buttonStyle(.bordered) }
        #endif
    }
}

#if !os(tvOS)
/// The system's accent, not the app's: `Color.accentColor` follows the app-wide tint here.
var systemAccent: Color {
    #if os(macOS)
    Color(nsColor: .controlAccentColor)
    #else
    Color(uiColor: .systemBlue)
    #endif
}
#endif

/// A page under Settings. `symbol` and `subtitle` lead the page on Apple TV.
struct SettingsPage<Content: View>: View {
    let title: String
    var symbol = "gearshape"
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: symbol, title: title, subtitle: subtitle) { content }
        #else
        Form { content }.settingsForm(title)
        #endif
    }
}

/// The panel around the diagnostic log list.
enum SettingsStyle {
    static let radius: CGFloat = 12
    static let groupFill = Color.primary.opacity(0.05)
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVSettingsView()
        #else
        FormSettingsView()
        #endif
    }
}

#if !os(tvOS)
// MARK: Settings on iPhone, iPad and Mac
// A native grouped form, as in the Settings app and System Settings: the app as the first card,
// icon-led rows that show their current value, switches in place, and subpages for the rest.

private enum FormMetrics {
    #if os(macOS)
    static let icon: CGFloat = 22, symbol: CGFloat = 11, hero: CGFloat = 52
    #else
    static let icon: CGFloat = 30, symbol: CGFloat = 15, hero: CGFloat = 64
    #endif
}

/// The coloured tile that leads a row.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .gray
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(.white)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon tile, title and an optional second line.
struct FormLabel: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { SettingsIcon(symbol: symbol, tint: tint) }
    }
}

/// A row that opens a page, with its current value before the chevron.
struct FormLink<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            LabeledContent {
                if let value, !value.isEmpty {
                    Text(value).lineLimit(1).foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
                }
            } label: { FormLabel(symbol: symbol, tint: tint, title: title) }
        }
    }
}

extension View {
    /// A button that fills its row: tinted text on iPhone, a plain clickable row on the Mac, where a
    /// form would otherwise draw a push button around the whole label.
    @ViewBuilder func formRowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain).contentShape(Rectangle())
        #else
        self
        #endif
    }
    /// Settings as the system draws them, like System Settings and the Settings app: the system's
    /// grouped background and row fills, and the system accent on switches and buttons instead of
    /// the app's neutral one. The scroll view spans the page and margins centre the rows; a narrowed
    /// frame left the toolbar's scroll edge as a band over the middle column only.
    func settingsForm(_ title: String) -> some View {
        GeometryReader { proxy in
            let extra = (proxy.size.width - Layout.settingsWidth) / 2
            let form = formStyle(.grouped).tint(systemAccent)
            // Only when there is room to spare: a zero margin would replace the system's own insets.
            if extra > 0 { form.contentMargins(.horizontal, extra, for: .scrollContent) } else { form }
        }
        .screenTitle(title, width: Layout.settingsWidth)
    }
    /// Switches in the system's own colour: green on iPhone and iPad, the accent on the Mac.
    @ViewBuilder func settingsSwitch() -> some View {
        #if os(iOS)
        tint(.green)
        #else
        self
        #endif
    }
}

struct FormSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    #if os(macOS)
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true
    #endif
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }

    var body: some View {
        @Bindable var store = store
        Form {
            // The app leads, like the account card in Settings; a waiting release sits right under it.
            Section {
                HStack(spacing: 14) {
                    AppMark(size: FormMetrics.hero)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Yingxia")).font(.title3.weight(.semibold))
                        if let version { Text(version).font(.subheadline).foregroundStyle(.secondary) }
                        Text(Brand.copyright).font(.caption).foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                if let latest = updates.available.first {
                    Button(action: updates.show) {
                        LabeledContent {
                            NewBadge()
                        } label: {
                            FormLabel(symbol: "gift.fill", tint: Brand.cyan, title: L10n.text("Yingxia %@ is available", latest.version),
                                      subtitle: L10n.text("New features are waiting for you."))
                        }
                    }.formRowButton()
                }
            }

            Section {
                ForEach(store.subscriptions) { entry in
                    let failure = store.subscriptionErrors[entry.address]
                    FormLink(symbol: failure == nil ? "list.bullet.rectangle.fill" : "exclamationmark.triangle.fill",
                             tint: failure != nil ? .orange : entry.enabled ? .blue : .gray,
                             title: entry.title, value: subscriptionValue(entry), warning: failure != nil) {
                        SubscriptionDetailView(entry: entry)
                    }
                }
                TextField(L10n.text("TVBox, M3U or TXT URL"), text: $store.subscriptionAddress, prompt: Text(L10n.text("TVBox, M3U or TXT URL")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit { add() }
                subscriptionActions
            } header: {
                Text(L10n.text("Subscriptions"))
            } footer: {
                if let message = store.error ?? store.notice { Text(message) }
            }

            Section(L10n.text("Accounts")) {
                FormLink(symbol: "play.tv.fill", tint: .pink, title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                FormLink(symbol: "music.note", tint: .black, title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                FormLink(symbol: "externaldrive.fill.badge.person.crop", tint: .brown, title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }

            Section(L10n.text("Playback")) {
                Toggle(isOn: $showsDanmaku) {
                    FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"),
                              subtitle: L10n.text("Bilibili's bullet comments, drawn over the video. You can also switch them in the player."))
                }
                .settingsSwitch()
                #if os(macOS)
                Toggle(isOn: $receivesCasts) {
                    FormLabel(symbol: "tv.and.mediabox.fill", tint: BilibiliMark.blue, title: L10n.text("Cast from the Bilibili App"),
                              subtitle: L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Yingxia")))
                }
                .onChange(of: receivesCasts) { _, on in
                    if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                }
                #endif
                FormLink(symbol: "play.fill", tint: Brand.indigo, title: L10n.text("Play a URL")) { PlayURLView() }
            }

            Section(L10n.text("Advanced")) {
                FormLink(symbol: "internaldrive", tint: .blue, title: L10n.text("Local Cache")) { CacheSettingsView() }
                FormLink(symbol: "cpu.fill", tint: .orange, title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() }
                FormLink(symbol: "doc.text.magnifyingglass", tint: .gray, title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
            }

            Section {
                if updates.available.isEmpty {
                    LabeledContent {
                        Button { Task { await updates.check(manual: true) } } label: {
                            if updates.checking { ProgressView().controlSize(.small) } else { Text(L10n.text("Check Now")) }
                        }
                        .disabled(updates.checking)
                    } label: {
                        FormLabel(symbol: "checkmark.circle.fill", tint: .green, title: L10n.text("Yingxia is up to date"),
                                  subtitle: updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) })
                    }
                }
                if !updates.currentNotes.isEmpty {
                    Button(action: updates.showCurrentNotes) {
                        FormLabel(symbol: "sparkles", tint: .purple, title: L10n.text("What's New in Version %@", updates.current))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.formRowButton()
                }
                FormLink(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
            } header: {
                Text(L10n.text("About"))
            } footer: {
                Text(L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source."))
            }
        }
        .settingsForm(L10n.text("Settings"))
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
    }

    private var canAdd: Bool { !store.importing && !store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func add() { if canAdd { Task { await store.importSubscription() } } }

    @ViewBuilder private var subscriptionActions: some View {
        #if os(macOS)
        // System Settings style: the actions as buttons at the trailing edge, the default one prominent.
        HStack {
            if !store.subscriptions.isEmpty {
                Button(L10n.text("Refresh All")) { Task { await store.refreshSubscriptions() } }.disabled(store.importing)
            }
            Spacer()
            if store.importing { ProgressView().controlSize(.small); ElapsedTime() }
            Button(L10n.text("Use Default URL")) { store.subscriptionAddress = Store.defaultURL }
            Button(store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription")) { add() }
                .buttonStyle(.borderedProminent).disabled(!canAdd)
        }
        #else
        Button { add() } label: {
            HStack {
                Text(store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription"))
                if store.importing { Spacer(); ElapsedTime().foregroundStyle(.secondary); ProgressView() }
            }
        }.disabled(!canAdd)
        Button(L10n.text("Use Default URL")) { store.subscriptionAddress = Store.defaultURL }
        if !store.subscriptions.isEmpty {
            Button(L10n.text("Refresh All")) { Task { await store.refreshSubscriptions() } }.disabled(store.importing)
        }
        #endif
    }

    private func subscriptionValue(_ entry: SubscriptionEntry) -> String {
        if store.subscriptionErrors[entry.address] != nil { return L10n.text("Couldn't refresh") }
        if !entry.enabled { return L10n.text("Off") }
        guard let copy = store.documents[entry.address] else { return L10n.text("Not loaded yet") }
        return L10n.text("%lld sources", copy.sites.count)
    }
}

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct SubscriptionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    var body: some View {
        let current = store.subscriptions.first { $0.address == entry.address } ?? entry
        let index = store.subscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        Form {
            Section {
                Toggle(isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } })) {
                    FormLabel(symbol: "list.bullet.rectangle.fill", tint: current.enabled ? .blue : .gray, title: L10n.text("Use This Subscription"))
                }
                .settingsSwitch()
                .disabled(store.importing)
                if store.subscriptions.count > 1 {
                    Toggle(isOn: Binding(get: { store.activeAddress == current.address },
                                         set: { on in store.selectSubscription(address: on ? current.address : nil) })) {
                        FormLabel(symbol: "square.stack.3d.up.fill", tint: .green, title: L10n.text("Show Only This Subscription"))
                    }
                    .settingsSwitch()
                    .disabled(store.importing)
                }
                LabeledContent(L10n.text("TVBox, M3U or TXT URL")) {
                    Text(current.address).lineLimit(2).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } footer: {
                if let failure { Text(L10n.text("Couldn't refresh: %@", failure)) }
                else if let copy { Text(L10n.text("Sources: %lld · Live playlists: %lld", copy.sites.count, copy.lives.count)) }
            }
            if store.subscriptions.count > 1 {
                Section(L10n.text("Order")) {
                    if index > 0 { Button(L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.subscriptions.count - 1 { Button(L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            Section {
                Button(L10n.text("Remove"), role: .destructive) { confirmsRemoval = true }
            }
        }
        .settingsForm(current.title)
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Playing a media address directly.
private struct PlayURLView: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    private var empty: Bool { address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        Form {
            Section {
                TextField(L10n.text("HTTP / HTTPS media URL"), text: $address, prompt: Text(L10n.text("HTTP / HTTPS media URL")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit(open)
                #if os(macOS)
                HStack { Spacer(); Button(L10n.text("Open Player"), action: open).buttonStyle(.borderedProminent).disabled(empty) }
                #else
                Button(L10n.text("Open Player"), action: open).disabled(empty)
                #endif
            }
        }
        .settingsForm(L10n.text("Play a URL"))
    }
    private func open() {
        guard !empty else { return }
        do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
        catch { store.error = error.localizedDescription }
    }
}
#endif

struct LicensesView: View {
    private var notices: String {
        (Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "DexLoom · MIT License"
    }
    var body: some View {
        #if os(tvOS)
        // Each paragraph is a row the remote can land on, which is how the page scrolls.
        SettingsPage(title: L10n.text("Open Source Licenses"), symbol: "doc.plaintext", subtitle: "Yingxia \(Brand.copyright)") {
            SettingsGroup {
                ForEach(Array(notices.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Button {} label: {
                        // The file is wrapped for a terminal; proportional text reads better reflowed.
                        Text(paragraph.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ParagraphStyle())
                }
            }
        }
        #else
        SettingsPage(title: L10n.text("Open Source Licenses")) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yingxia \(Brand.copyright)").font(.headline)
                    Link("www.getmegaportal.com", destination: Brand.website).font(.subheadline)
                }
            }
            Section {
                Text(notices)
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).selectable()
            }
        }
        #endif
    }
    #if os(tvOS)
    /// A glass row's focus, in a rounded rectangle: a capsule around a tall paragraph looked odd.
    private struct ParagraphStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
        private struct Plate: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var focused
            var body: some View {
                configuration.label
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .glassSurface(focused ? .regular.tint(.white.opacity(0.12)) : .identity, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: focused)
            }
        }
    }
    #endif
}

struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var level = "all"
    @State private var search = ""
    @State private var live = true
    @State private var dropped = 0
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var selected: LogEntry?
    private var filtered: [LogEntry] {
        entries.reversed().filter {
            (level == "all" || $0.level.rawValue == level) &&
            (search.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { heading; Spacer(minLength: 24); actions }
                VStack(alignment: .leading, spacing: 16) { heading; actions }
            }
            VStack(spacing: 0) {
                filters.padding(16)
                Divider()
                logList
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: live ? "circle.fill" : "pause.circle.fill").font(.system(size: live ? 6 : 11)).foregroundStyle(live ? Brand.accent : .secondary)
                    Text(L10n.text(live ? "Newest first · Updates every 2 seconds" : "Updates paused"))
                    Spacer()
                    Text("\(filtered.count) / \(entries.count)").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DiagnosticGrid.inset).padding(.vertical, 12)
            }
            .background(SettingsStyle.groupFill, in: RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            Text(L10n.text("Shows the latest 1,000 events from this run. Export includes retained log files."))
                .font(.caption).foregroundStyle(.secondary)
            if dropped > 0 {
                Label(L10n.text("Log overload: %lld events dropped", dropped), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.amber)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Brand.rose).selectable() }
        }
        .padding(Layout.gutter)
        .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackdrop()
        .screenTitle(L10n.text("Diagnostic Logs"))
        .sheet(item: $selected) { entry in DiagnosticDetail(entry: entry) }
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                if live { await refresh() }
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if !os(tvOS)
            Text(L10n.text("Runtime Activity")).font(.title2.weight(.bold))
            #endif
            Text(L10n.text("Inspect plugin requests and errors.")).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }.controlSize(.regular)
    }
    @ViewBuilder private var actionButtons: some View {
            Button { live.toggle() } label: {
                Label(L10n.text(live ? "Pause Logs" : "Resume Logs"), systemImage: live ? "pause.fill" : "play.fill")
            }.controlButton()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }.controlButton().accessibilityLabel(L10n.text("Refresh Logs")).help(L10n.text("Refresh Logs"))
            Menu {
                Button { export() } label: { Label(L10n.text("Export Logs"), systemImage: "square.and.arrow.up") }.disabled(exporting)
                #if os(macOS)
                Button { NSWorkspace.shared.open(Diagnostics.shared.directory) } label: {
                    Label(L10n.text("Open Log Folder"), systemImage: "folder")
                }
                #endif
                #if !os(tvOS)
                if let exportURL { ShareLink(item: exportURL) { Label(L10n.text("Share Logs"), systemImage: "square.and.arrow.up") } }
                #endif
            } label: {
                Label(L10n.text(exporting ? "Exporting Logs…" : "Log Files"), systemImage: "doc.text")
            }.controlButton()
    }
    private var filters: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search Logs"), text: $search).textFieldStyle(.plain).autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear Search"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            ChipRow {
                HStack(spacing: 6) {
                    levelButton("all", title: L10n.text("All Logs"), count: entries.count, color: Brand.accent)
                    ForEach(LogLevel.allCases, id: \.rawValue) { item in
                        levelButton(item.rawValue, title: item.title, count: entries.filter { $0.level == item }.count, color: item.tint)
                    }
                }
            }
        }
    }
    private func levelButton(_ value: String, title: String, count: Int, color: Color) -> some View {
        Button { level = value } label: {
            HStack(spacing: 7) {
                if value != "all" { Circle().fill(color).frame(width: 5, height: 5) }
                Text(title).fontWeight(.semibold)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 26, alignment: .trailing)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(level == value ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(level == value ? color.opacity(0.35) : .clear, lineWidth: 1) }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(level == value ? .isSelected : [])
    }
    private var logList: some View {
        let visible = filtered
        return GeometryReader { geometry in
            #if os(tvOS)
            let compact = true
            #else
            let compact = geometry.size.width < DiagnosticGrid.compactWidth
            #endif
            VStack(spacing: 0) {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        Text(L10n.text("Log Time")).frame(width: DiagnosticGrid.time, alignment: .leading)
                        Text(L10n.text("Log Level")).frame(width: DiagnosticGrid.level, alignment: .leading)
                        Text(L10n.text("Log Module")).frame(width: DiagnosticGrid.module, alignment: .leading)
                        Text(L10n.text("Log Message")).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: DiagnosticGrid.accessory, height: 1)
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, DiagnosticGrid.inset).frame(height: 36)
                    .background(Color.primary.opacity(0.025))
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            Button { selected = entry } label: { DiagnosticRow(entry: entry, compact: compact).foregroundStyle(.primary) }
                                .buttonStyle(.plain)
                            Divider().padding(.horizontal, DiagnosticGrid.inset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.text("No Logs"), systemImage: "waveform.path")
                        } description: {
                            Text(L10n.text(search.isEmpty && level == "all" ? "Plugin activity will appear here." : "Try another level or search term."))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportURL = try await Diagnostics.shared.export()
                #if os(macOS)
                if let exportURL { NSWorkspace.shared.activateFileViewerSelecting([exportURL]) }
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }
    private func refresh() async {
        let snapshot = await Diagnostics.shared.snapshot()
        if entries.last?.id != snapshot.entries.last?.id { entries = snapshot.entries }
        dropped = snapshot.dropped
        error = snapshot.fileError
    }
}

private extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: .secondary
        case .info: Brand.accent
        case .warning: Brand.amber
        case .error: Brand.rose
        }
    }
    var title: String {
        switch self {
        case .debug: L10n.text("Debug Logs")
        case .info: L10n.text("Info Logs")
        case .warning: L10n.text("Warning Logs")
        case .error: L10n.text("Error Logs")
        }
    }
}

// One grid for the header and every row. Content never selects its own layout.
private enum DiagnosticGrid {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 12
    static let time: CGFloat = 76
    static let level: CGFloat = 76
    static let module: CGFloat = 112
    static let accessory: CGFloat = 12
    static let compactWidth: CGFloat = 620
}

private struct DiagnosticRow: View {
    let entry: LogEntry
    let compact: Bool
    @State private var hovering = false
    var body: some View {
        Group {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    Text(entry.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(entry.level.rawValue.uppercased()).foregroundStyle(entry.level.tint)
                    Text(entry.category)
                }.font(.caption).foregroundStyle(.secondary)
                Text(entry.message).font(.body).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(.vertical, 18)
            #else
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                        badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                        module
                        Spacer(minLength: 0)
                    }
                    message.lineLimit(2, reservesSpace: true)
                }
                .padding(.vertical, 12)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                    timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                    badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                    module.frame(width: DiagnosticGrid.module, alignment: .leading)
                    message.lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: DiagnosticGrid.accessory)
                }
                .frame(height: 44)
            }
            #endif
        }
        .padding(.horizontal, DiagnosticGrid.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        #if !os(tvOS)
        .onHover { hovering = $0 }
        #endif
    }
    private var timestamp: some View {
        Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .lineLimit(1)
    }
    private var badge: some View {
        Text(entry.level.rawValue.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(entry.level.tint).frame(width: 60, height: 20)
            .background(entry.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
    private var module: some View {
        Text(entry.category).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var message: some View {
        let preview = entry.message.split(whereSeparator: \.isWhitespace).filter {
            !$0.hasPrefix("session=") && !$0.hasPrefix("request=") && !$0.hasPrefix("command=")
        }.joined(separator: " ")
        return Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.88))
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticDetail: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Pill(text: entry.level.title, tint: entry.level.tint)
                Text(entry.category).font(.headline)
                Spacer()
                Button(L10n.text("OK")) { dismiss() }.controlButton()
            }
            Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(entry.message).font(.system(.body, design: .monospaced)).selectable()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.contentPanel(cornerRadius: 14)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 720, minHeight: 360, idealHeight: 480)
        #elseif os(tvOS)
        .frame(width: 1100, height: 700)
        #endif
        .screenBackdrop()
    }
}

#if os(tvOS)
// MARK: Settings on Apple TV
// Laid out like the system's own Settings: the app on the left, a list on the right. Every row is
// one press of the remote: its current value sits at the trailing edge, a switch flips in place,
// and anything that needs typing or choosing opens a page of its own.

struct TVSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true

    var body: some View {
        TVSettingsLayout {
            TVSettingsHero()
        } list: {
            if !updates.available.isEmpty { updateSection }
            subscriptionSection
            TVSettingsSection(title: L10n.text("Accounts")) {
                TVSettingsLink(title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                TVSettingsLink(title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                TVSettingsLink(title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }
            TVSettingsSection(title: L10n.text("Playback"),
                              footer: L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Yingxia"))) {
                TVSettingsToggle(title: L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                TVSettingsToggle(title: L10n.text("Cast from the Bilibili App"), isOn: $receivesCasts)
                    .onChange(of: receivesCasts) { _, on in
                        if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                    }
                TVSettingsLink(title: L10n.text("Play a URL")) { TVPlayURLPage() }
            }
            TVSettingsSection(title: L10n.text("Advanced")) {
                TVSettingsLink(title: L10n.text("Local Cache")) { CacheSettingsView() }
                TVSettingsLink(title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() }
                TVSettingsLink(title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
            }
            if updates.available.isEmpty { updateSection }
            TVSettingsSection(title: L10n.text("About"),
                              footer: L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.")) {
                TVSettingsLink(title: L10n.text("Open Source Licenses")) { LicensesView() }
            }
        }
        .tabTitle(L10n.text("Settings"))
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
    }

    private var subscriptionSection: some View {
        TVSettingsSection(title: L10n.text("Subscriptions"), footer: store.notice) {
            ForEach(store.subscriptions) { entry in
                let failed = store.subscriptionErrors[entry.address] != nil
                TVSettingsLink(title: entry.title, value: subscriptionValue(entry), warning: failed) { TVSubscriptionPage(entry: entry) }
            }
            TVSettingsLink(title: L10n.text("Add Subscription")) { TVAddSubscriptionPage() }
            if !store.subscriptions.isEmpty {
                TVSettingsAction(title: L10n.text("Refresh All"),
                                 value: store.importing ? L10n.text("Importing…") : store.subscription.map { $0.importedAt.formatted(date: .abbreviated, time: .shortened) },
                                 busy: store.importing) { Task { await store.refreshSubscriptions() } }
                    .disabled(store.importing)
            }
        }
    }

    private func subscriptionValue(_ entry: SubscriptionEntry) -> String {
        if store.subscriptionErrors[entry.address] != nil { return L10n.text("Couldn't refresh") }
        if !entry.enabled { return L10n.text("Off") }
        guard let copy = store.documents[entry.address] else { return L10n.text("Not loaded yet") }
        return L10n.text("%lld sources", copy.sites.count)
    }

    private var updateSection: some View {
        TVSettingsSection(title: L10n.text("Software Update")) {
            if let latest = updates.available.first {
                Button(action: updates.show) {
                    TVSettingsRowLabel(title: L10n.text("Yingxia %@ is available", latest.version), chevron: true) { NewBadge() }
                }.glassRow()
            } else {
                TVSettingsAction(title: L10n.text("Check Now"),
                                 value: updates.checking ? L10n.text("Checking…") : updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) },
                                 busy: updates.checking) { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
            }
            if !updates.currentNotes.isEmpty {
                Button(action: updates.showCurrentNotes) {
                    TVSettingsRowLabel(title: L10n.text("What's New in Version %@", updates.current), chevron: true)
                }.glassRow()
            }
        }
    }
}

/// The page frame: a hero column on the left, vertically centred, and the scrolling list on the right.
struct TVSettingsLayout<Hero: View, List: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var list: List
    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            hero.frame(width: 560).frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 48) { list }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassRowInsets()
                    .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
        .padding(.horizontal, Layout.gutter)
        .screenBackdrop()
    }
}

/// The app as the left column of Settings: its icon, name, version and credit.
private struct TVSettingsHero: View {
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }
    var body: some View {
        VStack(spacing: 34) {
            AppMark(size: 300)
            VStack(spacing: 10) {
                Text(L10n.text("Yingxia")).font(.system(size: 48, weight: .bold))
                if let version { Text(version).font(.system(size: 26)).foregroundStyle(.secondary) }
                Text(Brand.copyright).font(.system(size: 22)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled run of rows with an optional note under it.
struct TVSettingsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer).font(.system(size: 22)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 8)
            }
        }
    }
}

/// The title on the leading edge; the current value, an accessory and a chevron on the trailing one.
struct TVSettingsRowLabel<Accessory: View>: View {
    let title: String
    var value: String? = nil
    var warning = false
    var busy = false
    var chevron = false
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(spacing: 18) {
            Text(title).font(.system(size: 29, weight: .medium)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 32)
            if busy { ProgressView() }
            if let value, !value.isEmpty {
                Text(value).font(.system(size: 27)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
            }
            accessory
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension TVSettingsRowLabel where Accessory == EmptyView {
    init(title: String, value: String? = nil, warning: Bool = false, busy: Bool = false, chevron: Bool = false) {
        self.init(title: title, value: value, warning: warning, busy: busy, chevron: chevron) { EmptyView() }
    }
}

/// A row that opens a page.
struct TVSettingsLink<Destination: View>: View {
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) { TVSettingsRowLabel(title: title, value: value, warning: warning, chevron: true) }
            .glassRow()
    }
}

/// A switch as a row: selecting it flips the value shown at the trailing edge.
struct TVSettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: { TVSettingsRowLabel(title: title, value: L10n.text(isOn ? "On" : "Off")) }
            .glassRow()
            .accessibilityValue(L10n.text(isOn ? "On" : "Off"))
    }
}

/// A row that does something in place.
struct TVSettingsAction: View {
    let title: String
    var value: String? = nil
    var busy = false
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TVSettingsRowLabel(title: title, value: value, busy: busy).foregroundStyle(destructive ? Brand.rose : Color.primary)
        }
        .glassRow()
    }
}

/// Text entry as a row: the title and the current text, like any other row. A focused tvOS text
/// field always draws the system's white platter, which sat inside the glass row as a box in a box,
/// so selecting the row opens the system's text entry instead, as Wi-Fi passwords do.
struct TVSettingsField: View {
    let title: String
    @Binding var text: String
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        Button { draft = text; editing = true } label: {
            TVSettingsRowLabel(title: title, value: text.isEmpty ? L10n.text("Not set") : text)
        }
        .glassRow()
        .alert(title, isPresented: $editing) {
            TextField(title, text: $draft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never).keyboardType(.URL)
            Button(L10n.text("Done")) { text = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }
}

/// A page under Settings: a large symbol and title on the left, its rows on the right.
struct TVSettingsSubpage<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        TVSettingsLayout {
            VStack(spacing: 30) {
                Image(systemName: symbol).font(.system(size: 120, weight: .regular)).foregroundStyle(.secondary)
                    .frame(height: 180)
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 44, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } list: { content }
        .screenTitle("")
    }
}

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct TVSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    var body: some View {
        let current = store.subscriptions.first { $0.address == entry.address } ?? entry
        let index = store.subscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        TVSettingsSubpage(symbol: "list.bullet.rectangle", title: current.title, subtitle: current.address) {
            TVSettingsSection(title: L10n.text("Subscription"),
                              footer: failure.map { L10n.text("Couldn't refresh: %@", $0) }
                                ?? copy.map { L10n.text("Sources: %lld · Live playlists: %lld", $0.sites.count, $0.lives.count) }) {
                TVSettingsToggle(title: L10n.text("Use This Subscription"),
                                 isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } }))
                    .disabled(store.importing)
            }
            if store.subscriptions.count > 1 {
                TVSettingsSection(title: L10n.text("Order")) {
                    if index > 0 { TVSettingsAction(title: L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.subscriptions.count - 1 { TVSettingsAction(title: L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            TVSettingsSection(title: L10n.text("Remove")) {
                TVSettingsAction(title: L10n.text("Remove"), destructive: true) { confirmsRemoval = true }
            }
        }
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Adding a subscription: the address, then add it or fill in the default one.
private struct TVAddSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var store = store
        let empty = store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        TVSettingsSubpage(symbol: "plus.rectangle.on.rectangle", title: L10n.text("Add Subscription")) {
            TVSettingsSection(title: L10n.text("Subscription"), footer: store.error ?? store.notice) {
                TVSettingsField(title: L10n.text("TVBox, M3U or TXT URL"), text: $store.subscriptionAddress)
                TVSettingsAction(title: store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription"), busy: store.importing) {
                    Task {
                        let before = store.subscriptions.count
                        await store.importSubscription()
                        if store.error == nil, store.subscriptions.count > before { dismiss() }
                    }
                }
                .disabled(store.importing || empty)
                TVSettingsAction(title: L10n.text("Use Default URL")) { store.subscriptionAddress = Store.defaultURL }
            }
        }
    }
}

/// Playing a media address directly.
private struct TVPlayURLPage: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    var body: some View {
        TVSettingsSubpage(symbol: "play.rectangle", title: L10n.text("Play a URL")) {
            TVSettingsSection(title: L10n.text("Playback")) {
                TVSettingsField(title: L10n.text("HTTP / HTTPS media URL"), text: $address)
                TVSettingsAction(title: L10n.text("Open Player")) {
                    do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
                    catch { store.error = error.localizedDescription }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
#endif
