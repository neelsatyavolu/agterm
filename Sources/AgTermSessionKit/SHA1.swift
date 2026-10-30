import Foundation

/// SHA-1, for the WebSocket handshake's `Sec-WebSocket-Accept` only (RFC 6455 requires it; it
/// protects nothing). Linux has no CryptoKit.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var bytes = message + [0x80]
        while bytes.count % 64 != 56 { bytes.append(0) }
        let bits = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                w[i] = (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[chunk + i * 4 + $1]) }
            }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotate(b, 30), a, t)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { word in (0..<4).map { UInt8((word >> UInt32(24 - $0 * 8)) & 0xff) } }
    }

    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
