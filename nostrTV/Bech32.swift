import Foundation

/// Bech32 encoding/decoding implementation for Nostr keys
/// Used to convert between hex keys and bech32 format (nsec/npub)
enum Bech32 {
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    enum Error: Swift.Error {
        case invalidCharacter
        case invalidChecksum
        case invalidLength
        case invalidHRP
        case invalidData
    }

    /// Encode data to Bech32 format
    /// - Parameters:
    ///   - hrp: Human-readable part (e.g., "nsec", "npub")
    ///   - data: Data to encode
    /// - Returns: Bech32 encoded string
    static func encode(hrp: String, data: Data) throws -> String {
        let values = convertBits(data: [UInt8](data), fromBits: 8, toBits: 5, pad: true)
        let checksum = createChecksum(hrp: hrp, values: values)
        let combined = values + checksum

        let hrpString = hrp
        let dataString = combined.map { charset[Int($0)] }.map(String.init).joined()

        return hrpString + "1" + dataString
    }

    /// Decode Bech32 string
    /// - Parameter string: Bech32 encoded string
    /// - Returns: Tuple of (hrp, data)
    static func decode(_ string: String) throws -> (hrp: String, data: Data) {
        guard let separatorIndex = string.lastIndex(of: "1") else {
            throw Error.invalidCharacter
        }

        let hrp = String(string[..<separatorIndex])
        let dataString = String(string[string.index(after: separatorIndex)...])

        var values: [UInt8] = []
        for char in dataString.lowercased() {
            guard let index = charset.firstIndex(of: char) else {
                throw Error.invalidCharacter
            }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: index)))
        }

        guard verifyChecksum(hrp: hrp, values: values) else {
            throw Error.invalidChecksum
        }

        // Remove checksum (last 6 chars)
        let dataValues = Array(values.dropLast(6))
        let decoded = convertBits(data: dataValues, fromBits: 5, toBits: 8, pad: false)

        return (hrp, Data(decoded))
    }

    // MARK: - Private Helpers

    private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8] {
        var acc: Int = 0
        var bits: Int = 0
        var result: [UInt8] = []
        let maxv: Int = (1 << toBits) - 1

        for value in data {
            acc = (acc << fromBits) | Int(value)
            bits += fromBits

            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            // Invalid padding
        }

        return result
    }

    private static func polymod(values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1

        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(value)
            for i in 0..<5 {
                chk ^= ((top >> i) & 1) == 0 ? 0 : gen[i]
            }
        }

        return chk
    }

    private static func hrpExpand(hrp: String) -> [UInt8] {
        var result: [UInt8] = []
        for char in hrp {
            result.append(UInt8(char.unicodeScalars.first!.value >> 5))
        }
        result.append(0)
        for char in hrp {
            result.append(UInt8(char.unicodeScalars.first!.value & 31))
        }
        return result
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let hrpExpanded = hrpExpand(hrp: hrp)
        let combined = hrpExpanded + values + [0, 0, 0, 0, 0, 0]
        let polymodValue = polymod(values: combined) ^ 1

        var checksum: [UInt8] = []
        for i in 0..<6 {
            checksum.append(UInt8((polymodValue >> (5 * (5 - i))) & 31))
        }

        return checksum
    }

    private static func verifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        let hrpExpanded = hrpExpand(hrp: hrp)
        let combined = hrpExpanded + values
        return polymod(values: combined) == 1
    }
}

// MARK: - String Character subscript extension
private extension String {
    subscript(index: Int) -> Character {
        return self[self.index(self.startIndex, offsetBy: index)]
    }
}
