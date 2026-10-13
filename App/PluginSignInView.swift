import SwiftUI
import TVCore

/// The QR code a source's plugin made for a Baidu Netdisk or Aliyun Drive sign-in. The plugin signs
/// in by itself once the code is scanned and confirmed, then the video it was opening plays.
struct PluginSignInView: View {
    let prompt: PluginSignIn.Prompt
    @State private var now = Date()

    private var name: String { L10n.text(prompt.drive == "baidu" ? "Baidu Netdisk" : "Aliyun Drive") }
    private var expired: Bool { now >= prompt.expires }

    var body: some View {
        // Side by side on a TV, iPad or Mac; stacked on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { code; details }
            ScrollView { VStack(alignment: .leading, spacing: spacing) { code; details } }
        }
        .padding(spacing)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 360)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackdrop()
        #endif
        .task {
            while !Task.isCancelled && !expired {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Sign In to %@", name)).font(.title2.weight(.bold))
                Text(L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("%@ needs this account for the line you chose. The video plays once you confirm.", prompt.source))
                    .font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if expired {
                Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("Waiting for you to scan…")).foregroundStyle(.secondary)
                }
            }
            Button(L10n.text(expired ? "Close" : "Cancel")) { PluginSignIn.shared.dismiss() }
                .settingsButton()
                .accessibilityIdentifier("pluginSignIn.cancel")
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            Group {
                if let content = prompt.content, let image = QRCode.image(content) {
                    Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                } else if let address = prompt.image {
                    AsyncImage(url: address) { phase in
                        if let image = phase.image { image.interpolation(.none).resizable().scaledToFit() }
                        else if phase.error != nil { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.black.opacity(0.5)) }
                        else { ProgressView().tint(.black) }
                    }
                    .accessibilityLabel(L10n.text("Sign-in code"))
                }
            }
            .padding(28).opacity(expired ? 0.15 : 1)
        }
        .frame(width: size, height: size)
    }

    private var size: CGFloat {
        #if os(tvOS)
        440
        #else
        240
        #endif
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        80
        #else
        32
        #endif
    }
}
