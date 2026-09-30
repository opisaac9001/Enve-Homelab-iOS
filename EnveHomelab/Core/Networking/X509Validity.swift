import Foundation

/// Reads the validity window from a DER-encoded X.509 certificate; Security only exposes it on iOS 18+.
enum X509Validity {
    struct Window: Equatable, Sendable {
        let notBefore: Date
        let notAfter: Date
    }

    static func parse(_ der: Data) -> Window? {
        let bytes = [UInt8](der)
        guard let certificate = element(in: bytes, at: 0), certificate.tag == 0x30,
              let tbs = element(in: bytes, at: certificate.contentStart), tbs.tag == 0x30 else { return nil }

        var cursor = tbs.contentStart
        var index = 0
        while cursor < tbs.end, let field = element(in: bytes, at: cursor) {
            if index == 0 && field.tag == 0xA0 {
                cursor = field.end
                continue
            }
            // serialNumber, signature, issuer, validity
            if index == 3 {
                guard field.tag == 0x30,
                      let first = element(in: bytes, at: field.contentStart),
                      let second = element(in: bytes, at: first.end),
                      let notBefore = time(bytes, first),
                      let notAfter = time(bytes, second) else { return nil }
                return Window(notBefore: notBefore, notAfter: notAfter)
            }
            index += 1
            cursor = field.end
        }
        return nil
    }

    private struct Element {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    private static func element(in bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        let first = Int(bytes[offset + 1])
        var length = first
        var headerLength = 2
        if first & 0x80 != 0 {
            let count = first & 0x7F
            guard (1...4).contains(count), offset + 2 + count <= bytes.count else { return nil }
            length = bytes[(offset + 2)..<(offset + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
            headerLength += count
        }
        let end = offset + headerLength + length
        guard end <= bytes.count else { return nil }
        return Element(tag: tag, contentStart: offset + headerLength, end: end)
    }

    private static func time(_ bytes: [UInt8], _ element: Element) -> Date? {
        guard let text = String(bytes: bytes[element.contentStart..<element.end], encoding: .ascii) else { return nil }
        let expanded: String
        switch element.tag {
        case 0x17:
            guard text.count >= 12, let year = Int(text.prefix(2)) else { return nil }
            expanded = (year >= 50 ? "19" : "20") + text
        case 0x18:
            expanded = text
        default:
            return nil
        }
        let digits = expanded.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber), expanded.hasSuffix("Z") else { return nil }

        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        let values = stride(from: 0, to: 14, by: 2).map { Int(digits.dropFirst($0).prefix(2))! }
        components.year = values[0] * 100 + values[1]
        components.month = values[2]
        components.day = values[3]
        components.hour = values[4]
        components.minute = values[5]
        components.second = values[6]
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
