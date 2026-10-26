import Foundation

/// gzip (RFC 1952), for `Content-Encoding: gzip`: Foundation's raw DEFLATE, with gzip's header
/// and trailer. Phones with little signal below ground then download a fraction of a feed;
/// URLSession unzips it on its own.
enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        // Magic, DEFLATE, no flags, no time, no extra flags, unknown OS
        var gzipped = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        gzipped.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            gzipped.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        return gzipped
    }

    /// Whether an Accept-Encoding header takes gzip (and doesn't refuse it with q=0).
    static func isAccepted(by acceptEncoding: String?) -> Bool {
        guard let acceptEncoding else { return false }
        return acceptEncoding.split(separator: ",").contains { coding in
            let parts = coding.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let name = parts.first, name == "gzip" || name == "*" else { return false }
            let quality = parts.dropFirst().first { $0.hasPrefix("q=") }.flatMap { Double($0.dropFirst(2)) }
            return quality.map { $0 > 0 } ?? true
        }
    }

    /// CRC-32 (IEEE), as gzip's trailer has it.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
