import Foundation

struct CompanionProviderBaseURLValidation: Equatable {
    let url: URL
    let normalizedString: String
    let usesLoopbackHTTP: Bool
}

enum CompanionProviderBaseURLError: LocalizedError, Equatable {
    case empty
    case invalid(String)
    case insecureHTTP(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return CompanionL10n.text("Fill API Base URL first.")
        case .invalid(let value):
            return String(format: CompanionL10n.text("API Base URL is invalid: %@. Use https://; only localhost, 127.0.0.1, and ::1 may use http://."), value)
        case .insecureHTTP(let value):
            return String(format: CompanionL10n.text("API Base URL is insecure: %@. Remote providers must use https://; only localhost, 127.0.0.1, and ::1 may use http://."), value)
        }
    }
}

enum CompanionProviderBaseURLPolicy {
    static var visibleGuidance: String {
        CompanionL10n.text("Remote APIs must use https://. Only localhost, 127.0.0.1, and ::1 may use http://; local HTTP sends API keys in plaintext, so connect only to trusted local services.")
    }

    static func validate(_ raw: String) throws -> CompanionProviderBaseURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompanionProviderBaseURLError.empty
        }

        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            let host = url.host,
            !host.isEmpty
        else {
            throw CompanionProviderBaseURLError.invalid(trimmed)
        }

        if scheme == "https" {
            return CompanionProviderBaseURLValidation(url: url, normalizedString: trimmed, usesLoopbackHTTP: false)
        }

        if scheme == "http", isLoopback(host: host) {
            return CompanionProviderBaseURLValidation(url: url, normalizedString: trimmed, usesLoopbackHTTP: true)
        }

        if scheme == "http" {
            throw CompanionProviderBaseURLError.insecureHTTP(trimmed)
        }

        throw CompanionProviderBaseURLError.invalid(trimmed)
    }

    static func warningMessage(for raw: String) -> String? {
        guard let validation = try? validate(raw), validation.usesLoopbackHTTP else {
            return nil
        }

        return CompanionL10n.text("Current local http:// address sends API keys in plaintext; use it only for trusted local services.")
    }

    static func errorMessage(for raw: String) -> String {
        do {
            _ = try validate(raw)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private static func isLoopback(host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
    }
}
