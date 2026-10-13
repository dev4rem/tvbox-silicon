import Foundation
import Testing
@testable import TVCore

private final class CloudLoginProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ticket = query.first { $0.name == "st" }?.value
        let mobile = url.path == "/account/mobileinfo"
        let valid = ticket == "approved-scan" && (!mobile || (query.contains { $0.name == "pr" && $0.value == "ucpro" } && query.contains { $0.name == "fr" && $0.value == "h5" }))
        let body = mobile && valid ? #"{"success":true,"data":{"serviceTicket":"mobile-service-ticket"}}"# : #"{"success":true,"data":{}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func cloudLoginSession(_ domain: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudLoginProtocol.self]
    for (cookieDomain, name, value) in [(domain, "__pus", "fixture"), ("unrelated.example", "private", "exclude-me")] {
        config.httpCookieStorage?.setCookie(HTTPCookie(properties: [.domain: cookieDomain, .path: "/", .name: name, .value: value])!)
    }
    return URLSession(configuration: config)
}

@Test func quarkScanPreservesWebCookieAndMobileServiceTicket() async throws {
    let session = cloudLoginSession("quark.cn")
    defer { session.invalidateAndCancel() }
    let login = try await CloudDriveQRLogin.complete(.quark, ticket: "approved-scan", session: session)
    #expect(login.cookie == "__pus=fixture")
    #expect(login.serviceTicket == "mobile-service-ticket")
}

@Test func quarkIncompleteTicketExchangeDoesNotReportSuccessfulLogin() async {
    let session = cloudLoginSession("quark.cn")
    defer { session.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
        try await CloudDriveQRLogin.complete(.quark, ticket: "missing-ticket", session: session)
    }
}

@Test func ucScanDoesNotRequireQuarkMobileTicket() async throws {
    let session = cloudLoginSession("uc.cn")
    defer { session.invalidateAndCancel() }
    let login = try await CloudDriveQRLogin.complete(.uc, ticket: "approved-scan", session: session)
    #expect(login.cookie == "__pus=fixture")
    #expect(login.serviceTicket == nil)
}

@Test func savedCloudAccountsRemainReadableAfterAddingMobileTicket() throws {
    let legacy = Data(#"{"quarkCookie":"__pus=old","ucCookie":"","ucToken":"","token":""}"#.utf8)
    var accounts = try JSONDecoder().decode(CloudDriveAccounts.self, from: legacy)
    #expect(accounts.quarkCookie == "__pus=old")
    #expect(accounts.quarkServiceTicket == nil)
    accounts.quarkServiceTicket = "mobile-ticket"
    let restored = try JSONDecoder().decode(CloudDriveAccounts.self, from: JSONEncoder().encode(accounts))
    #expect(restored.quarkServiceTicket == "mobile-ticket")
}
