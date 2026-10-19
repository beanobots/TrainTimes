import Foundation

/// A CBOR value (RFC 8949), only as much as App Attest's attestation and
/// assertion objects use: integers, byte and text strings, arrays, maps and
/// the simple values. Tags, floats and indefinite lengths are refused.
indirect enum CBOR: Hashable, Sendable {
    case unsigned(UInt64)
    /// -1 - n
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null
    case undefined

    enum Problem: Error, Equatable {
        case truncated, unsupported(UInt8), invalidText, duplicateKey, tooDeep, trailingBytes
    }

    subscript(key: String) -> CBOR? {
        guard case .map(let map) = self else { return nil }
        return map[.text(key)]
    }

    var bytes: [UInt8]? {
        if case .bytes(let bytes) = self { return bytes }
        return nil
    }

    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    var array: [CBOR]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// One whole value: anything after it is an error.
    static func decode(_ data: some Collection<UInt8>, maxDepth: Int = 8) throws -> CBOR {
        var reader = Reader(bytes: Array(data), maxDepth: maxDepth)
        let value = try reader.value(depth: 0)
        guard reader.position == reader.bytes.count else { throw Problem.trailingBytes }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        let maxDepth: Int
        var position = 0

        var remaining: Int { bytes.count - position }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw Problem.truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func take(_ count: UInt64) throws -> [UInt8] {
            guard count <= UInt64(remaining) else { throw Problem.truncated }
            let start = position
            position += Int(count)
            return Array(bytes[start..<position])
        }

        /// The argument after the initial byte's major type.
        mutating func argument(_ info: UInt8, initial: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24, 25, 26, 27:
                let count = 1 << Int(info - 24)
                var value: UInt64 = 0
                for byte in try take(UInt64(count)) {
                    value = value << 8 | UInt64(byte)
                }
                return value
            default:
                // 28-30 are reserved, 31 is an indefinite length
                throw Problem.unsupported(initial)
            }
        }

        mutating func value(depth: Int) throws -> CBOR {
            guard depth <= maxDepth else { throw Problem.tooDeep }
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1f
            switch major {
            case 0:
                return .unsigned(try argument(info, initial: initial))
            case 1:
                return .negative(try argument(info, initial: initial))
            case 2:
                return .bytes(try take(try argument(info, initial: initial)))
            case 3:
                guard let text = String(bytes: try take(try argument(info, initial: initial)), encoding: .utf8) else {
                    throw Problem.invalidText
                }
                return .text(text)
            case 4:
                let count = try argument(info, initial: initial)
                // Each item takes at least a byte, so a count can't outrun the input
                guard count <= UInt64(remaining) else { throw Problem.truncated }
                var items: [CBOR] = []
                items.reserveCapacity(Int(count))
                for _ in 0..<count {
                    items.append(try value(depth: depth + 1))
                }
                return .array(items)
            case 5:
                let count = try argument(info, initial: initial)
                guard count <= UInt64(remaining / 2) else { throw Problem.truncated }
                var map: [CBOR: CBOR] = [:]
                for _ in 0..<count {
                    let key = try value(depth: depth + 1)
                    let item = try value(depth: depth + 1)
                    guard map.updateValue(item, forKey: key) == nil else { throw Problem.duplicateKey }
                }
                return .map(map)
            case 7:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 23: return .undefined
                default: throw Problem.unsupported(initial)
                }
            default:
                // 6: tags
                throw Problem.unsupported(initial)
            }
        }
    }
}
