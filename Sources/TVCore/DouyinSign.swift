import Foundation

/// Douyin web's `a_bogus` request signature, which its category room lists (and other data
/// endpoints) require. Ported from the Apache-2.0 clean-room implementation in
/// Douyin_TikTok_Download_API (`src/dtk/signing/native/abogus.py` and `sm3.py`, by Evil0ctal and
/// contributors); see ThirdPartyNotices.txt. The page's SDK hashes the query, the body and the
/// User-Agent with SM3, packs them with the clock and the browser's geometry, and seals the result
/// with a modified RC4 under custom base64 alphabets.
public enum DouyinSign {
    /// The browser every signed request claims to be; the signature binds it.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private static let resultAlphabet = Array("Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe")
    private static let agentAlphabet = Array("ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe")
    private static let salt = "dhzx"
    private static let headerMagic = (3, 82)
    private static let sdkVersion = (1, 0, 1, 0)
    private static let payloadKey: UInt8 = 0xD3
    /// 2024-07-24T16:00:00Z; one field counts fortnights from here.
    private static let fortnightEpoch: Int64 = 1_721_836_800_000
    private static let pageID: Int64 = 6241
    private static let aid: Int64 = 6383
    private static let noiseMasks: [UInt8] = [0x91, 0x42, 0x2C]
    private static let dataMasks: [UInt8] = [0x6E, 0xBD, 0xD3]
    /// The order the fifty scalar fields (named by their slot numbers) are packed in.
    private static let fieldOrder = [
        34, 44, 56, 61, 73, 29, 70, 45, 35, 49, 38, 66, 51, 68, 28, 48, 64, 47, 30, 71,
        26, 55, 31, 69, 59, 40, 62, 63, 27, 72, 41, 74, 57, 52, 42, 39, 33, 67, 53, 43,
        65, 46, 36, 24, 60, 32, 79, 80, 84, 85,
    ]
    /// Where each hashed input leaves three bytes: two digest bytes verbatim and a "canary", the
    /// first digest byte from an offset that is not a sentinel.
    private struct Chain { let slots: (Int, Int, Int); let indices: (Int, Int); let canary: (offset: Int, sentinel: UInt8, fallback: UInt8) }
    private static let queryChain = Chain(slots: (48, 49, 51), indices: (9, 18), canary: (3, 11, 12))
    private static let bodyChain = Chain(slots: (52, 53, 55), indices: (10, 19), canary: (4, 8, 9))
    private static let agentChain = Chain(slots: (56, 57, 59), indices: (11, 21), canary: (5, 12, 13))
    /// What an untouched Chrome page reports about itself.
    private static let environmentFlags = 1
    private static let detectionFlags: Int64 = 14
    private static let nrFlags = 0x21
    private static let tripwireLocked = 3
    private static let callBucket = 6
    private static let browserInfo = "1920|947|1920|1032|1920|1032|1920|1080|Win32"

    /// The `a_bogus` value for a request whose query string (as sent, without `a_bogus`) is `query`.
    /// `random` is injectable so the output can be checked against the reference implementation.
    public static func aBogus(query: String, body: String = "", userAgent: String = userAgent,
                              now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                              random: () -> Double = { Double.random(in: 0..<1) }) -> String {
        var fields: [Int: UInt8] = [
            24: 41, 26: UInt8(truncatingIfNeeded: (now - fortnightEpoch) / (1000 * 60 * 60 * 24 * 14)), 27: UInt8(callBucket),
            // Milliseconds since the SDK started, plus three: a page that signs promptly.
            28: 3,
            35: UInt8(environmentFlags & 0xFF), 36: UInt8((environmentFlags / 256) & 0xFF),
            38: UInt8(nrFlags & 0xFF), 39: UInt8((nrFlags >> 8) & 0xFF), 66: UInt8(tripwireLocked),
        ]
        let info = jsBytes(browserInfo)
        let tail = jsBytes("\((now + 3) & 0xFF),")
        fields[79] = UInt8(info.count & 0xFF); fields[80] = UInt8((info.count >> 8) & 0xFF)
        fields[84] = UInt8(tail.count & 0xFF); fields[85] = UInt8((tail.count >> 8) & 0xFF)
        for (index, byte) in littleEndian(now, 6).enumerated() { fields[29 + index] = byte }
        for (index, byte) in littleEndian(detectionFlags, 4).enumerated() { fields[44 + index] = byte }
        for index in 0..<4 { fields[40 + index] = 0 }
        // The SDK plants Date.now() - 1 one call earlier.
        for (index, byte) in littleEndian(now - 1, 6).enumerated() { fields[60 + index] = byte }
        for (index, byte) in littleEndian(pageID, 4).enumerated() { fields[67 + index] = byte }
        for (index, byte) in littleEndian(aid, 4).enumerated() { fields[71 + index] = byte }
        for (chain, digest) in [(queryChain, digest(query)), (bodyChain, digest(body)), (agentChain, agentDigest(userAgent))] {
            fields[chain.slots.0] = digest[chain.indices.0]
            fields[chain.slots.1] = digest[chain.indices.1]
            fields[chain.slots.2] = digest[chain.canary.offset...].first { $0 != chain.canary.sentinel } ?? chain.canary.fallback
        }

        // Two of the noise sites report the environment rather than noise: the browser family, and
        // that the SDK's own tripwires are in place.
        let version = mask((sdkVersion.0, sdkVersion.1), random: random)
            + mask((sdkVersion.2, sdkVersion.3), random: random, low: probeNoise(random), high: tripwireNoise(random))
        var checksum: UInt8 = 0
        for byte in version { checksum ^= byte }
        for slot in fieldOrder { checksum ^= fields[slot]! }
        let body = fieldOrder.map { fields[$0]! } + info + tail + [checksum]
        let header = mask(headerMagic, random: random, high: headerNoise(userAgent, random))
        let sealed = rc4(key: [payloadKey], version + expand(body, random: random))
        return base64(header + sealed, resultAlphabet)
    }

    // MARK: Pieces

    /// SM3(SM3(text + salt)).
    private static func digest(_ text: String) -> [UInt8] { sm3(sm3(Array((text + salt).utf8))) }

    /// The User-Agent sealed with RC4 under a key from the environment flags, base64'd, hashed once.
    private static func agentDigest(_ agent: String) -> [UInt8] {
        let key: [UInt8] = [UInt8(environmentFlags / 256), UInt8(environmentFlags % 256), UInt8(detectionFlags % 256)]
        let sealed = rc4(key: key, jsBytes(agent.trimmingCharacters(in: .whitespacesAndNewlines)))
        return sm3(Array(base64(sealed, agentAlphabet).utf8))
    }

    /// A JavaScript string as the SDK turns it into bytes: one byte per UTF-16 unit below U+0100,
    /// two (big-endian) above.
    private static func jsBytes(_ text: String) -> [UInt8] {
        text.utf16.flatMap { unit -> [UInt8] in unit & 0xFF00 != 0 ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF)] }
    }

    private static func littleEndian(_ value: Int64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * Int64($0))) }
    }

    /// The SDK's RC4: a descending initial S-box and a multiplying key schedule.
    private static func rc4(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var box = [Int](repeating: 0, count: 256)
        for i in 0..<256 { box[255 - i] = i }
        var j = 0
        for i in 0..<256 {
            j = (j * box[i] + j + Int(key[i % key.count])) % 256
            box.swapAt(i, j)
        }
        var i = 0
        j = 0
        return data.map { byte in
            i = (i + 1) % 256
            j = (j + box[i]) % 256
            box.swapAt(i, j)
            return byte ^ UInt8(box[(box[i] + box[j]) % 256])
        }
    }

    /// Standard base64 grouping over a custom alphabet, `=`-padded.
    private static func base64(_ data: [UInt8], _ alphabet: [Character]) -> String {
        var out = ""
        for offset in stride(from: 0, to: data.count, by: 3) {
            let chunk = data[offset..<min(offset + 3, data.count)]
            var block = 0
            for index in 0..<3 { block = block << 8 | (index < chunk.count ? Int(chunk[chunk.startIndex + index]) : 0) }
            for (index, shift) in [18, 12, 6, 0].enumerated() where index <= chunk.count { out.append(alphabet[(block >> shift) & 0x3F]) }
        }
        return out + String(repeating: "=", count: (4 - out.count % 4) % 4)
    }

    /// Spreads two bytes over four, half of each from noise (or from the reports given).
    private static func mask(_ pair: (Int, Int), random: () -> Double, low: Int? = nil, high: Int? = nil) -> [UInt8] {
        let noise = Int(random() * 65535)
        let low = (low ?? noise) & 0xFF, high = (high ?? (noise >> 8)) & 0xFF
        return [(low & 0xAA) | (pair.0 & 0x55), (low & 0x55) | (pair.0 & 0xAA), (high & 0xAA) | (pair.1 & 0x55), (high & 0x55) | (pair.1 & 0xAA)].map { UInt8($0) }
    }

    /// Three body bytes and one noise byte become four carrier bytes.
    private static func expand(_ body: [UInt8], random: () -> Double) -> [UInt8] {
        var out: [UInt8] = []
        for offset in stride(from: 0, to: body.count, by: 3) {
            let group = Array(body[offset..<min(offset + 3, body.count)])
            guard group.count == 3 else {
                out.append(group[0])
                if group.count > 1, group[1] != 0 { out.append(group[1]) }
                continue
            }
            let noise = UInt8(Int(random() * 1000) & 0xFF)
            for index in 0..<3 { out.append((noise & noiseMasks[index]) | (group[index] & dataMasks[index])) }
            out.append((group[0] & noiseMasks[0]) | (group[1] & noiseMasks[1]) | (group[2] & noiseMasks[2]))
        }
        return out
    }

    /// The browser family, as a 40-wide band (Chrome's is 0).
    private static func headerNoise(_ agent: String, _ random: () -> Double) -> Int {
        let agent = agent.lowercased()
        let bands: [(String, Int)] = [("edg", 125), ("huawei", 170), ("firefox", 40), ("chrome", 0), ("safari", 81)]
        let base = bands.first { agent.contains($0.0) }?.1 ?? 210
        return (base + Int(random() * 40)) & 0xFF
    }
    private static func probeNoise(_ random: () -> Double) -> Int {
        let value = Int(random() * 240)
        return value > 109 ? value + value % 2 + 1 : value
    }
    /// "Tripwires present and locked" plus noise.
    private static func tripwireNoise(_ random: () -> Double) -> Int { (Int(random() * 255) & 0x4D) | 0xB2 }

    // MARK: SM3 (GB/T 32905-2016)

    static func sm3(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600, 0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E]
        var padded = message + [0x80]
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        func rotl(_ value: UInt32, _ bits: Int) -> UInt32 { let bits = bits % 32; return bits == 0 ? value : value << bits | value >> (32 - bits) }
        for offset in stride(from: 0, to: padded.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 68)
            for i in 0..<16 {
                w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(padded[offset + i * 4 + $1]) }
            }
            for i in 16..<68 {
                var x = w[i - 16] ^ w[i - 9] ^ rotl(w[i - 3], 15)
                x = x ^ rotl(x, 15) ^ rotl(x, 23)
                w[i] = x ^ rotl(w[i - 13], 7) ^ w[i - 6]
            }
            var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79CC4519 : 0x7A879D8A
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t, j), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff = j < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg = j < 16 ? e ^ f ^ g : (e & f) | (~e & g)
                let tt1 = ff &+ d &+ ss2 &+ (w[j] ^ w[j + 4])
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e; e = tt2 ^ rotl(tt2, 9) ^ rotl(tt2, 17)
            }
            state = zip(state, [a, b, c, d, e, f, g, h]).map { $0 ^ $1 }
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * UInt32($0))) } }
    }
}
