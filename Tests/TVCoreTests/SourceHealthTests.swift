import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://one.example/a.json")!
private func source(_ key: String, _ name: String) -> Site {
    Site(key: key, name: name, type: 1, api: "https://api.example/" + key, raw: ["key": .string(key)])
}
private struct Failure: Error {}

@MainActor @Test func repeatedFailuresStartADoublingCooldown() {
    let health = SourceHealth(file: nil), site = source("a", "A"), now = Date()
    #expect(health.status(site, origin: origin, now: now) == .unknown)
    health.record(site, origin: origin, seconds: 1, error: Failure(), now: now)
    #expect(health.status(site, origin: origin, now: now) == .unstable)
    #expect(!health.deprioritized(site, origin: origin, now: now))
    health.record(site, origin: origin, seconds: 1, error: Failure(), now: now)
    #expect(health.deprioritized(site, origin: origin, now: now))
    #expect(!health.deprioritized(site, origin: origin, now: now.addingTimeInterval(31 * 60)))
    health.record(site, origin: origin, seconds: 1, error: Failure(), now: now)
    #expect(health.deprioritized(site, origin: origin, now: now.addingTimeInterval(59 * 60)))
    #expect(!health.deprioritized(site, origin: origin, now: now.addingTimeInterval(61 * 60)))
    for _ in 0..<10 { health.record(site, origin: origin, seconds: 1, error: Failure(), now: now) }
    #expect(!health.deprioritized(site, origin: origin, now: now.addingTimeInterval(6 * 3600 + 1)))
    // One answer clears it.
    health.record(site, origin: origin, seconds: 1, error: nil, now: now)
    #expect(health.status(site, origin: origin, now: now) == .healthy)
}

@MainActor @Test func onlyTheSourcesOwnFailuresCount() {
    let health = SourceHealth(file: nil), site = source("a", "A")
    for _ in 0..<3 {
        health.record(site, origin: origin, seconds: 1, error: CancellationError())
        health.record(site, origin: origin, seconds: 1, error: TVError.unsupported("The plugin runtime is busy. Wait for the current source."))
    }
    #expect(health.status(site, origin: origin) == .unknown)
}

@MainActor @Test func slowAnswersAndOldRecords() {
    let health = SourceHealth(file: nil), site = source("a", "A"), now = Date()
    // A cold plugin's first answer alone does not mark it slow.
    health.record(site, origin: origin, seconds: 300, error: nil, now: now)
    #expect(health.status(site, origin: origin, now: now) == .healthy)
    for _ in 0..<5 { health.record(site, origin: origin, seconds: 30, error: nil, now: now) }
    #expect(health.status(site, origin: origin, now: now) == .unstable)
    #expect(health.status(site, origin: origin, now: now.addingTimeInterval(8 * 86400)) == .unknown)
}

@MainActor @Test func healthFollowsTheSourceAcrossMerges() throws {
    let health = SourceHealth(file: nil)
    let renamed = Site(key: "a@123456", name: "A", type: 1, api: "https://api.example/a", raw: ["key": .string("a")],
                       provenance: SourceProvenance(origin: origin, spider: nil))
    health.record(renamed, origin: URL(string: "https://other.example/")!, seconds: 1, error: Failure())
    health.record(source("a", "A"), origin: origin, seconds: 1, error: Failure())
    #expect(health.deprioritized(source("a", "A"), origin: origin))
}

@Test func failingChannelsAndSourcesGoLast() {
    let sites = [source("bad", "低端"), source("ok", "独播"), source("bad2", "低端[js]"), source("half", "欧乐"), source("half2", "欧乐[py]")]
    let failing: Set<String> = ["bad", "bad2", "half"]
    let arranged = SourceStrategy.arrange(sites, where: { _ in true }, failing: { failing.contains($0.key) })
    #expect(arranged.map { $0.key } == ["ok", "half2", "half", "bad", "bad2"])
    #expect(SourceStrategy.arrange(sites) { _ in true }.map { $0.key } == ["bad", "bad2", "ok", "half", "half2"])
}
