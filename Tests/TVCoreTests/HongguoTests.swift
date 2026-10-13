import Foundation
import Testing
@testable import TVCore

struct HongguoTests {
    @Test func builtInsAreIndependentAndDoNotRequireASubscriptionPlugin() throws {
        let base = URL(string: "https://example.com/config")!
        for sites in [[Site.bilibili], [Site.hongguo], Site.builtInSites] {
            let config = Subscription(origin: base, importedAt: .now, sites: sites, lives: [], raw: [:]).withBuiltInSites().withBuiltInSites()
            #expect(Set(config.sites.map(\.key)) == [Bilibili.siteKey, Hongguo.siteKey])
            #expect(config.sites.count == 2)
        }
        #expect(Site.hongguo.isBuiltIn && !Site.hongguo.isBilibili)
        #expect(Site.hongguo.canBrowse(jarURL: nil) && Site.hongguo.searchable)
        #expect(Site.hongguo.liteScript?.absoluteString == "assets://sites/Hongguo.js")
        #expect(try Site.hongguo.pluginExtension(origin: base)?.object?["cookie"] == nil)
    }

    @Test func quickJSCatalogAndAppProtocolKeepCompleteEpisodeIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = #"""
        import spider, { routerData, catalog, detail, search, webMedia } from 'assets://sites/Hongguo.js';
        import { fetchAppPlayUrl, deriveContentKey, decryptSpadeUrl } from 'assets://sites/hongguo/app-source.js';
        import { Buffer, crypto } from 'assets://sites/hongguo/crypto.js';
        import sm3 from 'assets://sites/hongguo/sm3.js';
        const sid = '7686713195246930968', vids = ['7686715217652223038', '7686715203864416318', '7686715213118835774', '7686715221196414014'];
        const page = data => '<script>window._ROUTER_DATA = ' + JSON.stringify({ loaderData: { page: data } }) + ';globalThis.untrusted = true;</script>';
        const series = { series_id: sid, series_name: 'A "quoted } title', series_cover: 'https://example.com/a.jpg', vid_list: vids, accessible_episode_cnt: 3 };
        const player = page({ isSuccess: true, series_id: sid, vid: vids[3], seriesDetail: series });
        export default { async home() {
            const checks = {};
            spider.init({ episode: 'Episode %@', name: 'Hongguo' });
            const parsed = detail(player, sid).list[0];
            checks.complete = parsed.vod_play_url.split('#').length === 4 && parsed.vod_play_url.endsWith(sid + '/' + vids[3]);
            checks.identity = parsed.vod_id === sid && parsed.vod_name === series.series_name;
            checks.noEval = !globalThis.untrusted;
            checks.empty = search(page({ isSuccess: true, searchList: [], totalCount: '0' })).list.length === 0;
            const results = search(page({ isSuccess: true, searchList: [{ video_data: { ...series, series_name: undefined, series_title: 'Search title' } }], totalCount: '100' }));
            checks.search = results.list[0].vod_name === 'Search title' && results.pagecount === 1;
            const list = catalog(page({ isSuccess: true, categoryRoute: { contentType: 'real-drama' }, recommendList: [series, series], pagination: { totalPages: 3 } }), 'real-drama', 2);
            checks.catalog = list.list.length === 1 && list.page === 2 && list.pagecount === 3;
            const rank = `<article><span>1</span><h2 id="rank-title-${sid}">Title</h2><a href="/detail?series_id=${sid}"><img src="https://example.com/a.jpg"></a></article><nav aria-label="榜单分页"><a href="/rank/hot-drama?page=3">3</a></nav>`;
            checks.ranking = catalog(rank, 'hot-drama', 1).pagecount === 3;
            const seo = '<script type="application/ld+json">' + JSON.stringify({ '@type': 'VideoObject', contentUrl: `https://hongguoduanju.com/video/public/${vids[0]}/360p.mp4` }) + '</script>';
            checks.noWrongVideo = webMedia(player + seo, sid, vids[3]) === null;
            let rejected = false; try { routerData('<script>window._ROUTER_DATA = {broken</script>'); } catch { rejected = true; }
            checks.malformed = rejected;
            checks.sm3 = sm3('abc').toString('hex') === '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0';
            checks.sha512 = crypto.createHash('sha512').update('abc').digest('hex').startsWith('ddaf35a193617aba');
            const key = '0123456789abcdef0123456789abcdef';
            const plain = Buffer.from('0' + key), raw = Buffer.alloc(34), previous = [246, 85];
            for (let i = 0; i < plain.length; i++) {
                raw[i + 1] = ((plain[i] + 21 + i.toString(2).split('1').length - 1) & 255) ^ previous[i & 1];
                previous[i & 1] = raw[i + 1];
            }
            raw[0] = 48 ^ raw[1] ^ raw[2];
            checks.contentKey = deriveContentKey(raw.toString('base64')).toString('hex') === key;
            const seed = Buffer.alloc(16, 7), constants = Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');
            const material = crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(seed).digest(), constants])).digest();
            const media = 'https://v3-reading.qznovelvod.com/video.mp4';
            const encrypted = Buffer.from(nativeCrypto({ op: 'aes', encrypt: true, key: material.subarray(0, 16).toString('base64'), iv: material.subarray(16, 32).toString('base64'), dataText: media }).data, 'base64');
            const spade = Buffer.concat([Buffer.from([0xa8, 0, 1, 0]), encrypted]).toString('base64');
            checks.spade = decryptSpadeUrl(spade, seed) === media;
            let calls = 0, wrongEpisode = false, badDestination = false;
            globalThis.req = (url, options) => {
                calls++;
                if (options.method === 'POST') {
                    const body = JSON.parse(options.body);
                    if (body.mixed_video_id_map['1004'][0] !== vids[3] || !options.headers['x-medusa'] || !options.headers['x-gorgon'] || options.redirect !== false) throw new Error('Invalid signed request');
                    return { code: 200, content: JSON.stringify({ code: 0, data: { [wrongEpisode ? vids[0] : vids[3]]: { video_model: JSON.stringify({ fallback_api: badDestination ? 'https://127.0.0.1/info' : 'https://vod.snssdk.com/info' }) } } }) };
                }
                return { code: 200, content: JSON.stringify({ video_info: { data: { key_seed: seed.toString('base64'), video_list: {
                    unsupported: { codec_type: 'bytevc2', quality_desc: '2160p', main_url: media },
                    selected: { codec_type: 'h264', quality_desc: '1080p', main_url: spade, spade_a: raw.toString('base64') }
                } } } }) };
            };
            const playback = await fetchAppPlayUrl(vids[3]);
            checks.app = calls === 2 && playback.contentKey === key && playback.url === media && playback.quality === '1080p';
            const sourcePlayback = await spider.play('Hongguo', sid + '/' + vids[3]);
            checks.mediaHeaders = sourcePlayback.header['User-Agent'].startsWith('com.phoenix.read/') && !('Referer' in sourcePlayback.header);
            wrongEpisode = true; calls = 0; rejected = false;
            try { await fetchAppPlayUrl(vids[3]); } catch { rejected = true; }
            checks.exactEpisode = rejected && calls === 1;
            wrongEpisode = false; badDestination = true; calls = 0; rejected = false;
            try { await fetchAppPlayUrl(vids[3]); } catch { rejected = true; }
            checks.destination = rejected && calls === 1;
            return { checks };
        } };
        """#
        let session = try await ScriptSession.start(api: "https://fixture.example/hongguo.js", key: "hongguo-fixture", ext: "", profile: folder, label: "hongguo-fixture", source: source)
        defer { session.close() }
        let envelope = try await session.call([:])
        let json = try #require(envelope["result"]?.string, "\(envelope)")
        let checks = try #require(JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))["checks"]?.object)
        #expect(checks.count == 17)
        for (name, result) in checks { #expect(result == .bool(true), "\(name)") }
    }

    @Test(arguments: [false, true]) func cencDecryptionPreservesOffsetsAndClearSubsamples(subsamples: Bool) throws {
        let fixture = makeMovie(subsamples: subsamples)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try fixture.encrypted.write(to: file)
        try HongguoMP4.decrypt(file: file, key: hex("2b7e151628aed2a6abf7158809cf4f3c"))
        let clear = try Data(contentsOf: file)
        #expect(clear.count == fixture.encrypted.count)
        #expect(clear.suffix(fixture.plain.count) == fixture.plain)
        #expect(clear.range(of: Data("encv".utf8)) == nil)
        #expect(clear.range(of: Data("senc".utf8)) == nil)
        #expect(clear.range(of: Data("avc1".utf8)) != nil)
    }

    @Test func malformedMediaFailsWithoutReturningAPartialMovie() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = makeMovie(subsamples: false).encrypted.dropLast()
        try data.write(to: file)
        #expect(throws: HongguoMP4.Failure.self) { try HongguoMP4.decrypt(file: file, key: Data(count: 16)) }
        #expect(throws: HongguoMP4.Failure.self) { try HongguoMP4.boxes(Data([0, 0, 0, 1, 109, 111, 111, 118]), 0..<8) }
    }

    @Test(arguments: [false, true]) func streamingDecryptsOnlyRequestedRangesAndSupportsTailMetadata(movieAtEnd: Bool) async throws {
        let fixture = makeMovie(subsamples: true, sampleCount: 180, prefixSize: 32000, movieAtEnd: movieAtEnd)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "fixture.mp4")
        try fixture.encrypted.write(to: file)
        let server = LocalMediaServer()
        let url = try await server.address(of: file, root: root)
        let stream = HongguoByteStream(url: url, key: hex("2b7e151628aed2a6abf7158809cf4f3c"), headers: [:], http: HTTPClient())
        let index = try await stream.metadata()
        #expect(index.duration == 180)
        #expect(index.samples.count == 180)
        let metadataStats = await stream.statistics
        #expect(metadataStats.received < fixture.encrypted.count / 20)
        // A request starts inside encrypted bytes, rather than at a sample or AES block boundary.
        let sample = index.samples[2]
        let start = sample.bytes.lowerBound + 32003
        let partial = try await stream.read(at: start, count: 13)
        #expect(partial == fixture.plain[32003..<32016])
        let beforeRepeat = await stream.statistics
        #expect(try await stream.read(at: start, count: 13) == partial)
        #expect(await stream.statistics.requests == beforeRepeat.requests)
        // A far seek fetches that sample, without downloading the intervening 147 seconds.
        let destination = index.samples[150].bytes.lowerBound + 32004
        try await stream.beginRequest(at: destination)
        #expect(try await stream.read(at: destination, count: 17) == fixture.plain[32004..<32021])
        let afterSeek = await stream.statistics
        #expect(afterSeek.received < fixture.encrypted.count / 10)
        #expect(afterSeek.cached <= HongguoByteStream.cacheLimit)
        await stream.clear()
        #expect(await stream.statistics.cached == 0)
    }

    @Test func forwardWindowStopsReadingAndCancellationDoesNotFetchTheRest() async throws {
        let fixture = makeMovie(subsamples: true, sampleCount: 180, prefixSize: 32000)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "fixture.mp4")
        try fixture.encrypted.write(to: file)
        let server = LocalMediaServer()
        let url = try await server.address(of: file, root: root)
        let stream = HongguoByteStream(url: url, key: hex("2b7e151628aed2a6abf7158809cf4f3c"), headers: [:], http: HTTPClient())
        let index = try await stream.metadata()
        let before = await stream.statistics
        let future = Task { try await stream.read(at: index.samples[90].bytes.lowerBound, count: 100) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await stream.statistics.requests == before.requests)
        future.cancel()
        await #expect(throws: CancellationError.self) { try await future.value }
        await stream.updatePosition(90)
        #expect(try await stream.read(at: index.samples[90].bytes.lowerBound, count: 100) == fixture.plain.prefix(100))
        #expect(await stream.statistics.received < fixture.encrypted.count / 10)
    }

    @Test(arguments: ["ignored", "wrong", "short"]) func streamingRejectsUnusableRangeResponses(response: String) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HongguoRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reader = HongguoRangeReader(url: URL(string: "https://fixture.example/\(response)")!, headers: [:], http: HTTPClient(session: session))
        await #expect(throws: (any Error).self) { try await reader.read(0..<32) }
    }

    @Test(arguments: ["referer-required", "referer-forbidden", "always-forbidden"])
    func streamingKeepsAppHeadersAndBoundsRefererRetry(policy: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HongguoRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://fixture.example/\(policy)?test=\(UUID())")!
        let reader = HongguoRangeReader(url: url, headers: ["User-Agent": "com.phoenix.read/test"], http: HTTPClient(session: session))
        if policy == "always-forbidden" {
            await #expect(throws: (any Error).self) { try await reader.read(0..<32) }
        } else {
            #expect(try await reader.read(0..<32).data.count == 32)
            #expect(try await reader.read(32..<64).data.count == 32)
        }
        let requests = HongguoRangeProtocol.requests(for: url)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "com.phoenix.read/test" })
        #expect(requests.first?.value(forHTTPHeaderField: "Referer") == nil)
        let ranges = requests.map { $0.value(forHTTPHeaderField: "Range") ?? "" }
        if policy == "referer-forbidden" {
            #expect(ranges == ["bytes=0-31", "bytes=32-63"])
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == nil })
        } else {
            #expect(ranges == (policy == "always-forbidden" ? ["bytes=0-31", "bytes=0-31"] : ["bytes=0-31", "bytes=0-31", "bytes=32-63"]))
            #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Referer") == Hongguo.mediaReferer })
        }
    }

    private func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    private func makeMovie(subsamples: Bool, sampleCount: Int = 1, prefixSize: Int = 5, movieAtEnd: Bool = false) -> (encrypted: Data, plain: Data) {
        func u32(_ values: Int...) -> Data { Data(values.flatMap { value in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }) }
        func box(_ type: String, _ data: Data) -> Data { u32(data.count + 8) + Data(type.utf8) + data }
        // NIST SP 800-38A AES-128-CTR vector; clear bytes must not consume the keystream.
        let clear1 = hex("6bc1bee22e409f96e93d7e117393172a"), clear2 = hex("ae2d8a571e03ac9c9eb76fac45af8e51")
        let cipher1 = hex("874d6191b620e3261bef6864990db6ce"), cipher2 = hex("9806f66b7970fdff8617187bb9fffdff")
        let prefix = subsamples ? Data(repeating: 0x41, count: prefixSize) : Data(), middle = subsamples ? Data(repeating: 0x42, count: 7) : Data()
        let plain = prefix + clear1 + middle + clear2, encrypted = prefix + cipher1 + middle + cipher2
        let tenc = box("tenc", u32(0) + Data([0, 0, 1, 16]) + Data(count: 16))
        let sinf = box("sinf", box("frma", Data("avc1".utf8)) + box("schm", u32(0) + Data("cenc".utf8) + u32(0x10000)) + box("schi", tenc))
        let stsd = box("stsd", u32(0, 1) + box("encv", Data(count: 78) + sinf))
        let subs = subsamples ? Data([0, 2, UInt8(prefixSize >> 8), UInt8(truncatingIfNeeded: prefixSize)]) + u32(16) + Data([0, 7]) + u32(16) : Data()
        let encryption = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff") + subs
        let senc = box("senc", u32(subsamples ? 2 : 0, sampleCount) + Data(repeating: encryption, count: sampleCount))
        func movie(_ offset: Int) -> Data {
            let table = stsd + box("stsz", u32(0, encrypted.count, sampleCount)) + box("stsc", u32(0, 1, 1, sampleCount, 1))
                + box("stco", u32(0, 1, offset)) + box("stts", u32(0, 1, sampleCount, 1000)) + senc
            return box("moov", box("trak", box("mdia", box("mdhd", u32(0, 0, 0, 1000, sampleCount * 1000, 0)) + box("minf", box("stbl", table)))))
        }
        let moov = movie(movieAtEnd ? 8 : movie(0).count + 8), mdat = box("mdat", Data(repeating: encrypted, count: sampleCount))
        return (movieAtEnd ? mdat + moov : moov + mdat, plain)
    }
}

private extension Data {
    init(repeating pattern: Data, count: Int) {
        self.init()
        reserveCapacity(pattern.count * count)
        for _ in 0..<count { append(pattern) }
    }
}

private final class HongguoRangeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observed: [URLRequest] = []
    static func requests(for url: URL) -> [URLRequest] { lock.withLock { observed.filter { $0.url == url } } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.observed.append(request) }
        let mode = request.url!.lastPathComponent
        let hasReferer = request.value(forHTTPHeaderField: "Referer") == Hongguo.mediaReferer
        let forbidden = mode == "always-forbidden" || (mode == "referer-required" && !hasReferer) || (mode == "referer-forbidden" && hasReferer)
        let range = request.value(forHTTPHeaderField: "Range")?.replacingOccurrences(of: "bytes=", with: "bytes ") ?? "bytes 0-31"
        let response = HTTPURLResponse(url: request.url!, statusCode: forbidden ? 403 : mode == "ignored" ? 200 : 206, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": mode == "wrong" ? "bytes 1-32/100" : range + "/100"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: mode == "short" ? 10 : 32))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
