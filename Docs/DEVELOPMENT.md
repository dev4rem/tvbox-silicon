# Developer guide

Build steps, runtime architecture, verification tools, and implementation notes for Yingxia. For an overview of the app, see the [README](../README.md).

Yingxia bundles a JVM, an Android ELF/JNI compatibility layer, and a DEX converter so it can run JAR, JavaScript, and Python plugins locally on the Mac. iOS and tvOS run plugin JARs in-process through an embedded JVM; this is verified on arm64 simulators, while physical devices and all-source parity are not yet verified. See the [on-device runtime status](on-device-runtime-status.md) for measurements and limitations.

## Build and run

### Requirements

- Xcode with the SDKs for the platforms you want to build.
- XcodeGen to regenerate `TVBox.xcodeproj` from `project.yml`.
- JDK 19 and Maven to build the bundled Mac plugin runtime.
- A standalone macOS Node.js binary and its distributed LICENSE for the JavaScript host (`NODE_BIN` and `NODE_LICENSE` can select them).
- [uv](https://docs.astral.sh/uv/) for the Python host. It installs a relocatable python-build-standalone CPython; `PYTHON_HOME` can select another relocatable prefix.
- Python 3 for localization checks and plugin inspection scripts.

The Mac app uses its bundled Java runtime; users do not need a separate Java installation. Physical iOS and tvOS devices require your own development team and signing configuration in Xcode. No account, certificate, or development team is preset.

### Prepare the project

Run these commands from the repository root:

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 19)"
Scripts/build-java-host.sh
Scripts/build-script-host.sh
Scripts/build-python-host.sh
xcodegen generate
```

The runtime script uses `MAVEN_BIN` if set, otherwise the local Maven binary under `build/tools/` when available, then `mvn` from `PATH`. It writes the Mac runtime to `build/JavaHost/`, which the Mac target includes as a folder resource. This generated directory is not committed, so prepare it before building a fresh checkout.

Open `TVBox.xcodeproj` and select a scheme:

| Scheme | Destination |
| --- | --- |
| `TVBox-macOS` | My Mac |
| `TVBox-iOS` | iPhone or iPad simulator/device |
| `TVBox-tvOS` | Apple TV simulator/device |

Each platform uses a separate bundle identifier. Generated app property lists are stored in `Config/`. Regenerate the project after changing `project.yml` or adding app source files or resources. Rebuild the Java host after changing `Runtime/JavaHost/`, the script host after changing `Runtime/ScriptHost/`, and the Python host after changing `Runtime/PythonHost/`. The script build copies Node and its license into `build/ScriptHost/`, and the Python build assembles CPython, the pinned spider libraries, and the host into `build/PythonHost/`; both are required Mac folder resources.

### Build the Mac app from the command line

```sh
xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-mac \
  CODE_SIGNING_ALLOWED=NO build
open build/DerivedData-mac/Build/Products/Debug/TVBox-macOS.app
```

## Features

- Import TVBox JSON subscriptions by URL, with a default URL prefilled.
- Save subscription snapshots, origin URLs, import dates, and favorite channels. A failed refresh preserves the last successfully imported configuration.
- Preserve plugin-specific fields such as `ext`, `spider`, and rules. Resolve relative URLs against the final response URL.
- Browse M3U and TVBox TXT live playlists, filter groups, search channels, and save favorites. Support configured User-Agent and Referer headers.
- Browse standard type 1/type 4 JSON sources: home pages, categories, search, pagination, details, playback sources, episodes, and resolved media URLs.
- Execute supported type 3 JAR sources locally on Mac, with a separate process, up to 180 seconds for initial conversion/startup, and a fresh 60-second deadline for each request.
- Play media with AVPlayer, display playback errors, and retry failed requests. On Mac, a private loopback HLS adapter handles supported image-prefixed MPEG-TS segments.
- Run the bundled DEX test JAR and inspect subscription plugins for DEX files and Android libraries. The inspection tool can check an inline MD5 fingerprint.

Playback depends on the source, media format, device decoder, and network availability. Unsupported features include full CatVod/Android API compatibility, arbitrary desktop JVM applications, web video detection, magnet links, multiple-quality playback responses, XML collection APIs, EPG, cloud sync, downloads, and a complete offline library. Complex playlist extensions and header requirements still need source-by-source verification.

## Built-in Hongguo source

Hongguo is appended alongside Bilibili to the displayed subscription, without changing
the imported document. It uses the bundled QuickJS runtime on macOS, iOS and tvOS.
The web catalog provides live-action, animated and AI dramas, four rankings, search,
and complete episode IDs. Search currently exposes one batch because the website
ignores its page parameter; category and ranking pagination follow the source.

Playback first requests the exact episode through the app's signed model endpoint
and its returned fallback endpoint. The adapter selects H.264/HEVC and resolves
encrypted media URLs locally. Playback registers a virtual MP4 with AVFoundation's
resource loader. Small HTTP Range requests read the MP4 sample tables (even when
the moov is at the end), then fetch and decrypt only requested samples using native
AES-CTR. Seeking reads the destination ranges without downloading the preceding
media. Responses that ignore Range or return a different range are rejected.
App media keeps the app endpoint's User-Agent. It omits Referer initially and retries
HTTP 403 once with the app Referer, retaining the successful policy for subsequent
ranges. Some CDN nodes reject the web browser headers even when another node works.

The player and resource loader use a roughly 60-second forward window. Decrypted
ranges have a 16 MB memory limit and expire as the playhead advances or seeks;
stopping playback cancels pending requests and clears those ranges. Playback creates
no complete movie on disk. Explicit offline downloads retain the complete-file
preparation path through `preparePlayback(_:forDownload:)`, with disposable files
eligible for cleanup after an hour at 512 MB, or after a day regardless of size.
If app playback is unavailable, the adapter tries the selected episode's public web
video. It does not substitute another episode or truncate the full episode list to
the web preview count. Availability and quality still depend on the upstream response.

`swift run TVBoxProbe --hongguo-check [series ID] [episode number]` checks catalog,
search, rankings, details, first-frame timing, bytes fetched before playback,
paused buffering, and forward/backward seeking. `--hongguo-play <series ID> [episode number]`
isolates playback from catalog/search availability. `HongguoTests`
cover the QuickJS signing/crypto bridge, exact episode selection, parsing and CENC
sample/subsample decryption using a NIST AES-CTR vector, middle-of-sample range reads,
tail metadata, cache reuse, cancellation, the forward window, and invalid HTTP Range
responses, app media headers, and bounded Referer retries. On tvOS, diagnostic logs
are stored under `Library/Caches/com.tvbox.yingxia/Logs` so they can be retrieved
from the app container after a device failure. Successful platform builds
do not establish playback on physical iPhone or Apple TV devices.

On 2026-10-12, the live probe returned all 69 episode IDs for series
`7686713195246930968`. Episodes 4 and 69 both played at 1080×1920 on macOS,
advanced past two seconds, and sought successfully near the end. Page 2 of all
seven catalog/ranking categories returned items. These are sampled live checks,
not a guarantee that every episode or title is available.

The subsequent streaming check on episode 69 resolved in 0.61 s and produced its
first frame in 1.93 s, after receiving 2.84 MB of the 13.28 MB, 157.5-second file.
With playback paused at 2.1 s, buffered media ended at 63.7 s and the received-byte
count stayed unchanged across consecutive checks. Seeking near the end and back
to 5 s both succeeded. These timings are one local network sample, not a latency
guarantee.

## Languages

English (`en`) is the source and fallback language. Traditional Chinese (`zh-Hant`), Simplified Chinese (`zh-Hans`), and Japanese (`ja`) are supported on all three platforms. The app follows the system's preferred languages or Apple's per-app language setting.

Subscription-provided source names, channel names, categories, and video titles retain their original text.

### Contributor conventions

- Write project documentation, source comments, and developer-facing diagnostics in English.
- Keep app-owned UI copy and user-facing errors in localization resources. Use `L10n.text("English source text")` with format arguments for dynamic values.
- Add every new key to all four `Sources/TVCore/Resources/<language>.lproj/Localizable.strings` files.
- Keep localized app names and permission text in `App/Resources/<language>.lproj/InfoPlist.strings`.
- Keep translated labels separate from persistent identifiers and plugin request values.
- Preserve upstream license text, third-party source content, and multilingual test fixtures.

## Project layout

| Path | Purpose |
| --- | --- |
| `App/` | Shared SwiftUI screens and platform-specific playback integration |
| `Sources/TVCore/` | Subscription models, networking, catalogs, localization, and runtime boundaries |
| `Sources/TVBoxProbe/` | Command-line plugin inspection and basic DEX execution probes |
| `Runtime/JavaHost/` | Mac JVM host, Android API adapters, and native plugin bridge |
| `Vendor/DexRuntime/` | Vendored experimental DEX interpreter and its license |
| `Tests/` | Core tests and controlled Java/DEX fixtures |
| `Scripts/` | Build, verification, and inspection tools |
| `Docs/` | Runtime evidence, limitations, and dependency notes |
| `project.yml` | XcodeGen project definition |

## Verification

After preparing the Mac runtime:

```sh
python3 Scripts/check-localizations.py
swift test
Scripts/verify.sh
```

The localization check verifies translation coverage, format arguments, and static Swift key references. `Scripts/verify.sh` runs the Swift tests and unsigned macOS, iOS device-SDK, and tvOS device-SDK builds. Successful builds do not establish plugin compatibility or device playback support.

`Scripts/test-tv-ui.sh <tvOS simulator UUID>` drives the Siri Remote in a separate tvOS bundle (no JAR runtime, isolated data) against `Scripts/qa-server.py`: `TVNavigationUITests` opens a video page whose details never arrive (`-qaPage open-detail:qa-stall:1`) and checks that Back returns to the previous page instead of leaving the app. Focus starts in the tab sidebar, so the test moves right into the page.

The command-line probe supports controlled static DEX execution and live-playlist inspection:

```sh
swift run TVBoxProbe App/Resources/runtime-probe.jar 'Ltvbox/RuntimeProbe;' run
swift run TVBoxProbe --live-check
```

Its execution mode only calls a no-argument static DEX method returning an integer. It does not expose the Mac app's full CatVod plugin host. The live check uses the network and reports parsed channel counts, not playback success.

### Test every source of a subscription

```sh
Scripts/test-sources.py [subscription-url] [--workers N] [--only text] [--output directory]
```

Runs each source through home, category or search, detail, play, and a fetch of the returned media URL, using the same persistent Java, JavaScript, and Python hosts as the Mac app (build it first with `Scripts/build-java-host.sh`). It needs the network, takes several minutes for a large subscription, and writes `build/site-test/results.json`. Use `--output` to preserve separate runs and repeat `--only` to select multiple sources. The harness keeps each completed JAR request’s parameters, response, and stderr under `evidence/`, and tries search when a home or category is empty. A pass means the returned media URL responded; it does not establish AVPlayer decoding or every HLS segment’s availability. Some sources are intermittent, so rerun before concluding that one is dead.

### Inspect a subscription JAR without executing it

```sh
mkdir -p build
curl --fail -L -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
  'https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt' -o build/fan.jar
swift run TVBoxProbe build/fan.jar
python3 Scripts/inspect-plugin.py build/fan.jar
```

### Regenerate the DEX test fixture

The fixture source is `Tests/Java/RuntimeProbe.java`. Compiled fixtures are included, so ordinary test runs do not need the fixture toolchain. Regeneration requires JDK 17+ and Google D8:

```sh
mkdir -p build/tools
curl --fail -L 'https://storage.googleapis.com/r8-releases/raw/8.3.37/r8lib.jar' -o build/tools/r8lib.jar
Scripts/build-runtime-probe.sh
```

## Plugin architecture and references

CatVod plugins may contain DEX, JVM classes, Android native libraries, or a guarded payload. The Mac host loads ordinary plugins without requiring `ftyguard_v8.so`; the FTY-specific path is selected only when that library is present. Ordinary DEX (including multidex) is converted with JVM stack frames, while original assets remain accessible. Plugin Init/helpers remain isolated from the host contract, and each source's `jar` override and relative extension path are respected.

Plugin JNI calls and native-library loads can run through the Android ARM64 guest rather than macOS `dlopen`. This does not supply a complete Android device: Android UI, unsupported native operations, private guards, login requirements, and unavailable servers can still prevent a source from loading. A successful subscription import or empty home response does not establish successful search or playback.

Each Mac source keeps a reusable process and persistent preferences. Idle processes stop after five minutes; requests have a 60-second deadline. Each type 3 source is routed like TVBox: a `.js` api runs in bundled Node, a `.py` api (or a legacy `py_` key whose `ext` is the script) runs in bundled CPython, and any other api is a JAR class. JavaScript spiders get HTTP, HTML parsing, module loading, and preference adapters. Python spiders get the CatVod `base.spider` API, `requests`, `lxml`, `bs4`, `pyquery`, `pycryptodome`, and `cryptography`, and their `localProxy` responses are served from a loopback port. Sources follow one strategy (`SourceStrategy`): only sources this platform can run are listed, in runtime order JSON API, Python, JavaScript, then JAR. Sources whose names normalize to the same site (for example `低端影视`, `影视 | 低端影视[js]`, and `🛣┃低端┃影视`) form one channel. Channels are ordered by their best runtime, and a channel's sources by runtime and then subscription order (JSON a, JSON b, Python a, Python b, and so on). The Sources list, the Watch Now source picker and default, and Global Search all use this order; search also runs each runtime in its own lane so slow JVM searches never delay the others. Web video detection remains unsupported. The Mac host supports CatVod stream proxy responses and the FTY cloud-drive proxy contract; other plugin-specific proxy implementations may still require adapters.

The basic DexLoom interpreter remains available for controlled tests on all platforms. It does not provide complete Android plugin compatibility.

- [On-device runtime status](on-device-runtime-status.md)
- [Third-party dependency notes](THIRD_PARTY_NOTICES.md)
- [FongMi/TV reference implementation](https://github.com/FongMi/TV), reference commit `c616c0aa3613e87529791587a9f71b78c278c991`, GPL-3.0. An unmodified local reference checkout may exist at `reference/FongMi-TV/`; that directory is ignored by this project.
- [DexLoom](https://github.com/speedyfriend433/DexLoom), MIT. Its license and version record are retained under `Vendor/DexRuntime/`.

Third-party subscription plugin binaries are downloaded on demand and are not bundled with the app. The test JAR is a project-owned fixture. The current ATS configuration permits HTTP subscriptions and local-network media; TLS certificate validation remains enabled.

### Desktop player

On macOS, playback opens in an independent, resizable window with remembered window geometry, standard minimize/close controls, fullscreen, and Picture in Picture. The library stays usable while a video plays. AVKit provides the timeline, volume, AirPlay, embedded audio/subtitle selection when available, and 0.5–2× playback speed. The bottom options menu adds looping, fit/fill, floating above other windows, and retry. Closing the player releases the stream and its local HLS proxy; selecting another item reuses the player window.

Keyboard shortcuts apply in the player window: Space plays/pauses, Left/Right seeks 10 seconds (Shift: 60 seconds), Up/Down adjusts volume, M toggles mute, F toggles fullscreen, and Escape exits fullscreen. Seeking is limited to the stream's available seekable range; live channels without DVR cannot rewind. Standard Command-W closes the window.

The player uses Apple's AVKit inside SwiftUI. KSPlayer (https://github.com/kingslay/KSPlayer) and IINA (https://github.com/iina/iina) were evaluated as references; no code or dependencies were imported from them. This upgrade does not extend AVFoundation's supported codecs or add external subtitle files.

After building the macOS target into `build/Verify-mac`, `bash Scripts/test-player.sh` generates a local test clip with FFmpeg and runs a native window/playback smoke check. It requires Apple silicon, Xcode, FFmpeg, and a logged-in desktop session.

Host regression checks: `Scripts/test-java-host.sh` and `python3 Scripts/test-script-host.py`. Run these after preparing the corresponding runtimes.

### Runtime diagnostic logs

Open Settings → Diagnostic Logs, or choose View Logs on the JAR runtime page. The log viewer filters by level and keyword, can pause live refresh, refreshes manually, and exports; on Mac it can also open the log folder directly. The page shows the latest 1,000 entries from the current run; exports include the history retained on disk.

Logs are stored as JSON Lines under `com.tvbox.yingxia/Logs/` in the app's Application Support directory. They record JAR downloads, DEX inspection, source/session/request correlation, request durations, retries, timeouts, process exits, and plugin stdout/stderr. Full request parameters and results are not logged. Common credentials and URL query strings are redacted, but plugin-specific output should still be checked before sharing.

A background utility queue writes logs in 250 ms batches; producers only append to a bounded in-memory queue and never wait for the disk. Each entry is capped at 2,048 characters and the queue at 512 entries; under overload, warnings and errors are kept first and the number of dropped entries is recorded. Each log file holds up to about 2 MB, and 4 files are retained; an exported copy holds up to about 8 MB. Plugin output is reassembled into lines, overlong lines are truncated, and pipes are drained continuously so that log writes to disk never block a plugin. The viewer refreshes every 2 seconds and only while it is visible.

A disk write failure does not make parsing fail: the page shows the error, keeps recent logs in memory, and retries after 30 seconds when new logs arrive. An abrupt exit may lose the last batch that has not reached the disk; entries are not synced to disk one by one. These logs provide evidence for locating problems; they do not mean that every plugin compatibility issue or upstream source failure has been fixed.

### tvOS channel guide

The channel page follows [YouTube TV’s published live-guide design](https://blog.youtube/news-and-events/youtube-tv-live-guide-and-library/): focused-channel details above compact full-width rows, neutral category pills, and high-contrast remote focus. Search opens on demand from the header; refresh is a compact icon. Hold Select on a channel for the favorite action. Playlists supply channel names, groups, and logos, so the guide does not invent programme schedules or preview imagery. iOS and macOS retain their existing channel layout.

### tvOS playback recovery

Playback failures use a flat full-screen layout with a prominent heading, channel/video name, and wide focusable Retry, Go back, and Show details controls. Show details expands the server message beneath the controls, and Hide details collapses it. The remote’s Back button returns to the previous screen. The visual reference is a [YouTube TV playback-error screenshot published in its support community](https://support.google.com/youtubetv/thread/342048636/playback-error?hl=en), rather than YouTube’s proprietary source code. This app retains local retry and diagnostics instead of imitating a feedback service.

### Global search and recommendations

Watch Now displays the selected source's home recommendations and remembers the source choice. JAR home responses merge `homeContent(true)` with a nonempty `homeVideoContent()` list; JavaScript sources may supply `homeVod()`. Index sources (`indexs: 1`) and name-only ranking entries are displayed as recommendations and open Global Search by title; entries with real video IDs from ordinary sources open their own details. An empty recommendation list stays empty instead of substituting a category. The latest four source recommendation lists are cached in memory for ten minutes, with explicit refresh and subscription invalidation. TVBox artwork header suffixes are parsed into actual HTTP headers; posters are downsampled and held in a bounded decoded-image cache.

Global Search queries supported sources with `searchable` omitted or set to `1`, with at most four concurrent requests. Results append to a stable poster grid and retain their source for details/playback. Source chips filter the grid; select a source and use its “More” link to browse subsequent search pages. Failed sources appear in a separate sheet and can be retried independently. Search state survives opening details and switching app sections. Search history stores the latest 20 keywords locally and can be cleared. The latest six completed searches are cached in memory for five minutes; subscription changes invalidate them. Already-started sources are searched first. Stopping or replacing a search prevents stale results from being displayed; an already running plugin call may still finish in its host process. iOS/tvOS search only their supported standard APIs.

On tvOS, Global Search uses SwiftUI’s native `.searchable` and `.searchSuggestions` interface: the keyboard, recent-search suggestions, and results share the screen and native focus navigation. Searches start after a 650 ms typing pause; suggestions complete the query through the same search field. Explicit submissions and opened results add the query to history, avoiding partial queries in history during typing. Source filters, progress, stop/resume, and failure retry remain in the results area. Details and source pagination preserve search state on return. macOS and iOS keep their existing search controls.

Simulator verification: recent-search completion returned 24 fixture results, and opening a result and returning preserved the results. Individual character selection through Device Hub’s simulated remote was inconsistent on tvOS 27; physical Siri Remote typing and dictation remain unverified.

Search design references: [YouTube's TV search guide](https://www.fetchtv.com.au/pdf/Fetch_YouTube_UserGuide.pdf) for keyboard/suggestions/results layout, and [Apple's SwiftUI media catalog sample](https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui) for native implementation. These describe public interaction patterns; YouTube's proprietary tvOS implementation was not inspected.

Plugin downloads are shared across source sessions, with a five-minute, four-entry/40 MB memory cache. A verified SHA-256 disk cache survives app restarts (up to 16 URL records and 80 MB of downloaded artifacts). After five minutes, HTTP ETag/Last-Modified revalidation checks for changes; without validators the plugin is downloaded and hashed again. For JAR sources, a changed payload at the same URL starts a new plugin session while preserving the source profile. Source and detail loading show download progress when a byte total is available, then preparation stages and converted/reused component counts. Demand-driven conversion does not have a fixed total, so it uses an activity indicator instead of an estimated percentage. JAR conversion artifacts are shared on disk, keyed by DEX SHA-256 and host transformation version. Process locks and atomic publication prevent concurrent conversion races; invalid JAR artifacts are regenerated. On iOS/tvOS, interrupted preparation resumes automatically at class boundaries: completed classes remain reusable, and a completed DEX-to-JVM stage is checkpointed before compatibility rewriting. Restarting repeats only unfinished stages, not previously completed classes. Checkpoints are validated before reuse; partial writes are discarded under the class lock. A class interrupted during DEX conversion must restart that class. Resuming requires the cache to remain available and the plugin content and transformation version to match. Each source still has its own runtime and preferences. A local startup sample measured 9.587 seconds for first conversion versus 3.928–4.749 seconds with the shared artifact; these are plugin startup measurements, not an end-to-end search latency guarantee.

Manual Mac search check: the existing query `兰香` displayed three results within the first approximately five-second UI observation, continued to 30 searched sources, retained results when switching sections, and reused the completed query without entering loading again. This is one observed run; source network latency varies.

### Audit source loading and search

Export a normalized subscription with `swift run TVBoxProbe --subscription-export URL > build/subscription.json`, then run `python3 Scripts/audit-source-loading.py build/subscription.json --output build/source-audit`. The audit tests home and search independently using the same bundled hosts, records empty results separately, respects per-source plugins, and keeps evidence under the output directory. Use `--query`, `--keys`, or `--searchable-only --limit 6` to select a bounded sample. It does not test playback or confirm every source in a sampled subscription.

For an end-to-end subscription audit, run `python3 Scripts/audit-subscription-playback.py --inputs Fixtures/subscription-audit.txt --output build/playback-audit`. It imports every listed URL with TVCore, tries sources until a media response is verified, and keeps search/detail/player responses and failure stages. HLS checks follow a playlist into a media segment; HTTP 200 HTML is rejected. It tests up to four titles and three playback lines per source, and does not claim a decoder/playback test. `--resume` keeps completed evidence. `python3 Scripts/audit-subscription-directories.py --resume` follows reachable directory roots from that audit until a child subscription passes. Playback URLs may expire.

### Cloud drive accounts (Mac)

Open Settings → Cloud Drive Accounts → Manage Cloud Accounts. Quark and UC offer an embedded official sign-in page; finish signing in and choose Save Login. Existing Quark/UC cookies, an optional UC token, and an Aliyun refresh token can also be entered manually. Credentials stay in the app's private Application Support directory (directory mode 0700, file mode 0600) and are passed to the subscription plugins the user runs. Saving restarts plugin sessions; retry the source afterward.

The host supplies `Cloud-drive` JSON (`quarkCookie`, `ucCookie`, `ucToken`, `token`) and existing `cookie`/`uc_cookie`/`token` extension references through a per-process loopback server with an unguessable URL. It preserves other source settings. CatVod proxy responses retain status, headers, range requests, and streaming bodies. FTY `ProxyOrigin.getUrl` and `getOwnProxyUrl` use the host's server, including its separate `proxyDrive` routing. Recent proxy traffic keeps the source process alive.

Validation includes controlled configuration/streaming checks, Swift tests, and a real WoGG initialization with synthetic credentials: all four cloud initializers fetched the configuration, and Quark retained credential state. This does **not** verify account authorization or end-to-end playback. Real playback still needs the user's valid account, provider access, compatible media, and a working source. Android plugin QR dialogs are not emulated; use the account settings login page.

### Cloud drive playback

A plugin's cloud-drive file (a `/drive/` address on the plugin's loopback proxy) is not played through that proxy. FTY's Quark proxy starts a set of download threads for every range AVPlayer opens; on a 4K file (1.4–2 GB) the abandoned ranges exhausted the embedded JVM's threads (`OutOfMemoryError: unable to create native thread`) and playback stalled at 0 bytes/s. Instead, the Java host's `directMedia` command asks the proxy for two bytes and records the CDN request the plugin makes to answer them (`HttpDiagnostics` sees every plugin OkHttp call): its URL, headers and file length. `CloudStreams` then serves AVPlayer from that address through a resource loader, in 2 MB chunks over up to six parallel connections (drives cap each connection), reading a bounded window ahead of each reader. A file whose audio sits far from its video is read in two places at once, so the stream tracks several readers and never cancels a chunk someone waits on. The container comes from the file's first bytes, not its name (a 4K MP4 named `.mp3`). An expired address is resolved again through the plugin; when no CDN request is revealed, playback falls back to the proxy.

Two AVFoundation rules the loader follows: answer from a copied `Data`, never a slice of a cached chunk, and never call `respond(with:)` or `finishLoading` while holding the delegate queue (AVFoundation can wait on that queue while holding its request lock, which deadlocked playback). When a newer request arrives for the same stream, deliveries to older requests pause briefly so AVFoundation's cancel lands first; bytes handed to a request it had just abandoned made it report the movie as damaged. `CloudStreamsTests` cover byte-exact reads, two distant readers, expired addresses, and, with `TVBOX_CLOUD_MEDIA=<an MP4>`, AVPlayer opening, playing and seeking a movie through the loader three times; they serve ranges from memory (`RangeServer`), not a shared port.

On the living-room Apple TV (2026-10-13), FTY's 4K Quark episodes (1.63 GB MP4, and a 1.94 GB MP4 named `.mp3`) played at 3840×2160 in real time with 2.0–3.8 MB/s from the CDN, where the proxy had managed 0.4–0.6 MB/s and then stalled. One network and one account; not a guarantee for every drive or file.

The same lookup covers every drive whose proxy fetches the file with ranged requests, whatever the plugin calls its route: `/drive/` addresses and the plugin's own `/media` proxy (Fish's drives answer `/proxy?do=…`, which the bridge routes to `/media`). Fish downloads ranges over `HttpURLConnection` on its own threads, not OkHttp, so the converted plugin's `getResponseCode()`/`getInputStream()` calls are rewritten to `HttpDiagnostics` as well (conversion `host-v13`; a version bump converts each plugin class again once). A proxy that does not answer the probe with a byte range (a playlist, a page) is left to the proxy at once. Downloads of drive episodes use the same direct address (`Store.resolveDownload`), and take their file type from the first bytes. Playback that still streams through a plugin logs `plugin proxy stream drive|media do=<x>` in Diagnostics.

`TVBoxProbe --drive-check <subscription> <source> [search]` opens a source's first video and, for each drive it offers, prints DIRECT (CDN host, size, lookup time, read speed) or PROXY. Run it with `TVBOX_DISABLE_SANDBOX=1` from a remote shell, where `sandbox-exec` cannot start the JVM. Drives that need an account read it from `CloudDrive/accounts.json`, as the app does. On 2026-10-13 Fish's 玩偶 Quark episodes (原画 and 无限) went DIRECT with a 0.3–0.6 s lookup; 夸克智 failed inside the plugin (HTTP 404 from Quark), Baidu hung without an account, and 123/光鸭 need accounts.

### Plugin requests that never end

Android plugins wait for a QR sign-in by showing a dialog and polling until someone scans it. This host shows no dialog, so without a host check the request never returns, and because a source takes one request at a time, every later request for that source waits behind it. FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC, 嘟嘟 is Baidu, 阿狸 is Aliyun. On 2026-10-13 its Baidu and Aliyun lines without an account still hung after 120 s.

- `HttpDiagnostics.qrLoginDrive` recognizes the QR endpoints of Quark, UC, Baidu (`passport.baidu.com` getqrcode/unicast) and Aliyun (`passport.aliyundrive.com/newlogin/qrcode/…` and the open-API variants). Quark and UC throw `CloudLoginRequired` and the app offers its own sign-in. Baidu and Aliyun keep the plugin's sign-in: `LoginPrompt` reads the code from the plugin's own code-creating response (Baidu's `imgurl`, Aliyun's `codeContent`), writes it to `login-prompt.json` in the source's session folder (`_folder`), and moves the request's deadline out by 180 s. `PluginSignIn` (Swift) watches that file while a non-search request runs and `PluginSignInView` shows the code; once it is scanned the plugin saves the account itself (Baidu `files/mybd_cookie`, Aliyun `files/ali_*`) and the playback request continues. A code-creating response without a code still hands the sign-in back. The detail page doesn't start a title on a Baidu or Aliyun line.
- FTY saves the account after the scan but only its Android dialog code tells the waiting request, so that request would wait out its deadline. `LoginPrompt.confirms` spots the confirmation (Baidu's `qrbdusslogin` setting `BDUSS`, Aliyun's `qrCodeStatus: CONFIRMED`), the request ends with `SignedIn` 1.5 s (Baidu) or 4 s (Aliyun) later, and `InProcessHost` retires that runtime and serves the request again from a fresh one with a fresh deadline. The fresh spider reads the saved account. `login-prompt.json` gets `signedIn: true`, and the app closes the code. On the living-room Apple TV (2026-10-14) a Baidu scan returned the playback link 24 s after confirming, including the restart.
- Settings → Cloud Drive Accounts also signs in to Baidu Netdisk and Aliyun Drive with a code to scan (`CloudDriveQRLogin`: Baidu's passport QR login sets `BDUSS`/`STOKEN`/`PTOKEN`, kept as `baiduCookie`; Aliyun's `bizExt` carries the refresh token, kept as `token`), on the Mac too. FTY keeps its own copies as guard-encrypted JSON (`files/mybd_cookie`: `bduss`, `stoken`, `ptoken`, `devuid`; `files/ali_user`: `refresh_token`). `CloudDriveBridge.syncFtyAccounts` writes the app's Baidu account into `mybd_cookie` (`DexNative.encrypt`) before the spider starts, and offers a sign-in only the plugin has back through `plugin-accounts.json`, which `EmbeddedJarHost` adopts into the app's accounts. A sign-in through the plugin's code is adopted too (its `signedIn` notice carries the account), so one scan serves every source. Signing out also removes the plugin's copies.
- Every request carries a stop time (`stopAt`): the app's `cancel` (going back, choosing another title, the worker's 15-minute limit) sets it to now, and the spider's deadline (`EmbeddedJarHost.deadline`: play 90 s, search 60 s, others 150 s, from when the spider starts on it) sets it ahead. `SystemClock.sleep`, OkHttp calls and the rewritten `HttpURLConnection` calls check it and throw `RequestStopped`, an `Error`, so plugin `catch (Exception)` loops can't swallow it. The app reports it as `source_timeout`.
- A request still running 15 s after its stop time (`OpeningGate.STUCK_GRACE_MILLIS`; it waits somewhere the host can't reach) gets its spider retired: the next request opens a fresh one, and the old runtime closes when that request returns.
- Host commands (`directMedia`, `recoverProxy`) bypass the plugin request slots (`SerializedPluginWorker.immediate`), so starting a working video never waits behind a stuck line.
- `embedded-jvm.log` logs `PLUGIN_REQUEST <time> <kind> [flag=…]`, `PLUGIN_STOPPED`, `PLUGIN_RUNTIME_RETIRED`; past 2 MB at launch it moves to `embedded-jvm.previous.log`.

### Software update and What's New

Release notes live in `website/public/releases.json`, which the website serves at `https://yingxia.getmegaportal.com/releases.json` and every app target also bundles. Each release has a `version`, a `date`, `links` keyed by platform (`macos`, `ios`, `tvos`; a platform without a link did not get the release, so its users are not told about it), and `features` with an SF Symbol, a `title` and a `detail` in `en`, `zh-Hans`, `zh-Hant` and `ja` (an optional `platforms` list limits a feature). `ReleaseFeedTests` checks that the file parses and that every feature is translated.

The app checks the feed at launch and when it becomes active again, at most every six hours. A newer release for the platform is presented once as a "Something New Is Here" sheet (Mac: Get the Update opens the link; Apple TV: a QR code of the link); afterwards it stays as a New badge on Settings (sidebar on Mac, tab or More on iPhone/iPad) and a Software Update row at the top of Settings. After an update, the first launch shows What's New for every release since the previous version that has features for the platform; Settings → What's New in Version x.y reopens it. Fresh installs skip What's New. The Mac app menu has Check for Updates…. Sheets wait while a video plays.

To release: add the new version's entry at the top of `releases.json` before building, so the build bundles its own notes, then deploy the website after the downloads are uploaded; publishing the entry is what tells existing users.

QA (Debug builds): `-qaReleaseFeed <url>` reads another feed (a `file://` path works on simulators), `-qaVersion 1.0.1` pretends to be another version, and launch-argument defaults such as `-updates.lastVersion 1.0.1` or `-updates.announcedVersion 1.1` set the recorded state for one run. With `-qaSection`, update checks only run when `-qaReleaseFeed` is given.
