import SwiftUI
import TVCore

/// Sign in to a cloud drive by scanning a code with the drive's phone app; there is no browser
/// on Apple TV. (The Mac uses it for Baidu and Aliyun.) The saved sign-in reaches the plugins on
/// their next request.
struct CloudQRLoginView: View {
    let drive: CloudDriveQRLogin.Drive
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var login: CloudDriveQRLogin?
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0

    private var name: String {
        switch drive {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .baidu: L10n.text("Baidu Netdisk")
        case .aliyun: L10n.text("Aliyun Drive")
        }
    }
    private var title: String {
        switch drive {
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .baidu, .aliyun: L10n.text("Sign In to %@", name)
        }
    }
    var body: some View {
        // Side by side on a TV, iPad or Mac; stacked on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: codeSpacing) { code; details }
            ScrollView { VStack(alignment: .leading, spacing: codeSpacing) { code; details } }
        }
        .padding(codeSpacing)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 360)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackdrop()
        #endif
        .task(id: attempt) { await run() }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title2.weight(.bold))
                Text(L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            status
            HStack(spacing: 16) {
                #if os(iOS)
                if let login, !login.code.isEmpty, let url = URL(string: login.code) {
                    Link(L10n.text("Open %@", name), destination: url).settingsButton(prominent: true)
                }
                #endif
                if expired || error != nil {
                    Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
                }
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton()
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            if let login, let address = login.image {
                // Baidu serves its code as an image.
                AsyncImage(url: address) { phase in
                    if let image = phase.image { image.interpolation(.none).resizable().scaledToFit() }
                    else if phase.error != nil { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.black.opacity(0.5)) }
                    else { ProgressView().tint(.black) }
                }
                .accessibilityLabel(L10n.text("Sign-in code"))
                .padding(28).opacity(expired ? 0.15 : 1)
            } else if let login, let image = QRCode.image(login.code) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                    .padding(28).opacity(expired ? 0.15 : 1)
            } else if error == nil {
                ProgressView().tint(.black)
            }
            if expired {
                Image(systemName: "arrow.clockwise").font(.system(size: 64, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            }
        }
        .frame(width: codeSize, height: codeSize)
    }
    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if login != nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }
    private func run() async {
        login = nil; expired = false; error = nil
        do {
            let login = try await CloudDriveQRLogin.start(drive)
            self.login = login
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                switch try await login.poll() {
                case .waiting: continue
                case .expired: expired = true; return
                case .signedIn(let credentials):
                    var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
                    switch drive {
                    case .quark:
                        accounts.quarkCookie = credentials.cookie
                        accounts.quarkServiceTicket = credentials.serviceTicket
                    case .uc: accounts.ucCookie = credentials.cookie
                    case .baidu: accounts.baiduCookie = credentials.cookie
                    case .aliyun: accounts.token = credentials.refreshToken ?? ""
                    }
                    try accounts.save()
                    dismiss()
                    signedIn()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
    private var codeSize: CGFloat {
        #if os(tvOS)
        440
        #else
        240
        #endif
    }
    private var codeSpacing: CGFloat {
        #if os(tvOS)
        80
        #else
        32
        #endif
    }
}
