import Foundation

extension ISO8601DateFormatter {
    /// Parses ISO 8601 timestamps with or without fractional seconds.
    static func parseFlexible(_ value: String) -> Date? {
        withFractionalSeconds.date(from: value) ?? plain.date(from: value)
    }

    // ISO8601DateFormatter is thread-safe for parsing, so sharing instances is fine.
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
