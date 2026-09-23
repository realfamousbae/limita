import Foundation

extension ISO8601DateFormatter {
    /// Parses ISO 8601 timestamps with or without fractional seconds.
    /// Fractions longer than milliseconds (e.g. microseconds from Python backends) are
    /// dropped, since the formatter rejects them on some macOS versions.
    static func parseFlexible(_ value: String) -> Date? {
        if let date = withFractionalSeconds.date(from: value) ?? plain.date(from: value) {
            return date
        }
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let digits = value[value.index(after: dot)...].prefix { $0.isNumber }
        let trimmed = value[..<dot] + value[digits.endIndex...]
        return plain.date(from: String(trimmed))
    }

    // ISO8601DateFormatter is thread-safe for parsing, so sharing instances is fine.
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
