import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func kilobytes(_ value: Int64) -> String {
        bytes(value * 1024)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    static func uptime(since bootTime: Date, now: Date = .now) -> String {
        duration(max(0, now.timeIntervalSince(bootTime)))
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    static func temperature(_ celsius: Int) -> String {
        Measurement(value: Double(celsius), unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func count(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

enum APIDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = (try? fractional.parse(string)) ?? (try? plain.parse(string)) { return date }
        return normalized(string).flatMap { (try? fractional.parse($0)) ?? (try? plain.parse($0)) }
    }

    /// .NET servers emit up to seven fractional digits and, for server-local times, no zone; those are read as this device's zone.
    private static func normalized(_ string: String) -> String? {
        guard let match = string.wholeMatch(of: /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?/) else { return nil }
        let fraction = match.2.map { "." + $0.dropFirst().prefix(3) } ?? ""
        let zone = match.3.map(String.init) ?? {
            let offset = TimeZone.current.secondsFromGMT() / 60
            return String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        }()
        return "\(match.1)\(fraction)\(zone)"
    }
}
