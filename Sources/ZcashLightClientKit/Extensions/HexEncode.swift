//
//  HexEncode.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 12/13/19.
//

import Foundation
import CommonCrypto

/**
Thanks Stack Overflow (once again) https://stackoverflow.com/questions/39075043/how-to-convert-data-to-hex-string-in-swift
*/
struct HexEncodingOptions: OptionSet {
    public static let upperCase = HexEncodingOptions(rawValue: 1 << 0)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension Data {
    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        z_hexEncodedString(data: self, options: options)
    }

    /// Decodes a hex-encoded string into raw bytes. Returns `nil` for odd-length input or any
    /// non-hex character. Accepts both upper- and lower-case digits.
    init?(hexEncoded string: String) {
        func decodeNibble(_ char: UInt16) -> UInt8? {
            switch char {
            case 0x30 ... 0x39:
                return UInt8(char - 0x30)
            case 0x41 ... 0x46:
                return UInt8(char - 0x41 + 10)
            case 0x61 ... 0x66:
                return UInt8(char - 0x61 + 10)
            default:
                return nil
            }
        }

        self.init(capacity: string.utf16.count / 2)
        var even = true
        var byte: UInt8 = 0
        for char in string.utf16 {
            guard let value = decodeNibble(char) else { return nil }
            if even {
                byte = value << 4
            } else {
                byte += value
                self.append(byte)
            }
            even.toggle()
        }
        guard even else { return nil }
    }
}

func z_hexEncodedString(data: Data, options: HexEncodingOptions = []) -> String {
    let hexDigits = Array((options.contains(.upperCase) ? "0123456789ABCDEF" : "0123456789abcdef").utf16)
    var chars: [unichar] = []

    chars.reserveCapacity(2 * data.count)
    for byte in data {
        chars.append(hexDigits[Int(byte / 16)])
        chars.append(hexDigits[Int(byte % 16)])
    }

    return String(utf16CodeUnits: chars, count: chars.count)
}
