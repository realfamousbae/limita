import Foundation

// MARK: - Models

struct ServiceLimit: Codable, Equatable {
    var used: Double
    var total: Double
    var resetsAt: Date?

    var remaining: Double { max(0, total - used) }
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, used / total)
    }

    var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    static let placeholder = ServiceLimit(used: 0, total: 1, resetsAt: nil)
}

struct ServiceStatus: Codable, Equatable {
    var fiveHour: ServiceLimit
    var weekly: ServiceLimit
    var lastUpdated: Date?
    var isLoggedIn: Bool
    var errorMessage: String?

    static let empty = ServiceStatus(
        fiveHour: .placeholder,
        weekly: .placeholder,
        lastUpdated: nil,
        isLoggedIn: false,
        errorMessage: nil
    )
}

enum Service: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .codex: return "⚡"
        case .claude: return "🤖"
        }
    }

    var loginURL: String {
        switch self {
        case .codex: return "https://chatgpt.com"
        case .claude: return "https://claude.ai"
        }
    }
}

enum AppState: Equatable {
    case hidden
    case pill
    case expanded
}
