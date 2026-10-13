import SwiftUI
import TVCore

@main struct TVBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = Store()
    @State private var updates = Updates()
    #if os(iOS)
    /// An Apple TV's Douyin code, scanned with the Camera.
    @State private var douyinHandoff: DouyinHandoff.Link?
    #endif
    init() {
        #if os(macOS)
        // Use thin overlay scrollers app-wide. With "Show scroll bars: Always" or a mouse attached,
        // AppKit otherwise draws wide legacy scrollers that crowd poster grids and the episode rail.
        // The app's own defaults domain takes precedence over the global setting.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(updates)
                #if !os(tvOS)
                // tvOS draws plain buttons and section links in the tint, so it keeps the neutral default.
                .tint(Brand.accent)
                #endif
                .task { Diagnostics.shared.record(.info, "app", "Application scene opened") }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil || QALaunch.page != nil { await QALaunch.start(store); return }
                    #endif
                    await store.restoreSubscription()
                }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil, UserDefaults.standard.string(forKey: "qaReleaseFeed") == nil { return }
                    #endif
                    // Builds before 1.1 recorded no version, so earlier use shows as a saved subscription.
                    await updates.launched(returning: UserDefaults.standard.string(forKey: "subscriptionAddress") != nil)
                }
                #if os(tvOS) || os(macOS)
                .task { BilibiliCastController.shared.start(store) }
                #endif
                #if os(iOS)
                .onOpenURL { url in if let link = DouyinHandoff.Link(url) { douyinHandoff = link } }
                .sheet(item: $douyinHandoff) { DouyinHandoffView(link: $0) }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        Task { _ = await Diagnostics.shared.snapshot() }
                    }
                    #if os(tvOS) || os(macOS)
                    // Phones only see the TV while the app is open.
                    if phase == .background { BilibiliCastController.shared.stop() }
                    if phase == .active { BilibiliCastController.shared.start(store) }
                    #endif
                    #if !os(macOS)
                    if phase == .background { DownloadsLifecycle.enteredBackground() }
                    if phase == .active { DownloadsLifecycle.becameActive() }
                    #endif
                    // Apple TV and Mac sessions run for days; look again when the app comes back.
                    if phase == .active { Task { await updates.check() } }
                }
                #if os(tvOS)
                .preferredColorScheme(.dark)
                #endif
                #if os(macOS)
                .frame(minWidth: 920, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("Check for Updates…")) { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
            }
        }
        #endif
    }
}
