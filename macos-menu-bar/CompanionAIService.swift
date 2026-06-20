import Foundation

struct CompanionAIProviderConfiguration {
    let name: String
    let baseURL: String
    let apiKey: String
    let model: String
}

enum CompanionAIProviderError: LocalizedError {
    case unavailable
    case noSelectedProfile
    case missingBaseURL(profileName: String)
    case invalidBaseURL(profileName: String, value: String)
    case missingAPIKey(profileName: String)
    case missingModel

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return CompanionL10n.text("Companion AI is unavailable. Open AI Settings and configure a provider.")
        case .noSelectedProfile:
            return CompanionL10n.text("No AI provider is configured. Open AI Settings and add one first.")
        case .missingBaseURL(let profileName):
            return CompanionL10n.format("\"%@\" is missing an API Base URL. Open AI Settings and try again.", profileName)
        case .invalidBaseURL(let profileName, let value):
            return CompanionL10n.format("\"%@\" has an invalid API Base URL: %@", profileName, CompanionProviderBaseURLPolicy.errorMessage(for: value))
        case .missingAPIKey(let profileName):
            return CompanionL10n.format("\"%@\" is missing an API Key. Open AI Settings and try again.", profileName)
        case .missingModel:
            return CompanionL10n.text("Companion AI is missing a model. Open AI Settings and try again.")
        }
    }
}

private enum CompanionAIRequestError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case requestFailed(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return CompanionProviderBaseURLPolicy.errorMessage(for: value)
        case .invalidResponse:
            return CompanionL10n.text("The provider returned an unrecognized response.")
        case .requestFailed(let status, let message):
            if status == 429 {
                return message.isEmpty
                    ? CompanionL10n.text("The provider request was rate-limited. Try again later.")
                    : CompanionL10n.format("The provider request was rate-limited. Try again later: %@", message)
            }

            if message.isEmpty {
                return CompanionL10n.format("Provider request failed: HTTP %d.", status)
            }
            return CompanionL10n.format("Provider request failed: HTTP %d, %@.", status, message)
        case .emptyResponse:
            return CompanionL10n.text("The provider returned no text.")
        }
    }
}

struct CompanionAIChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    let companionName: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        companionName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.companionName = companionName
    }
}

enum CompanionAIInputSource: String, Codable, Equatable, CaseIterable {
    case selectedText
    case clipboard
    case manual

    var title: String {
        switch self {
        case .selectedText:
            return CompanionL10n.text("Selected Text")
        case .clipboard:
            return CompanionL10n.text("Clipboard")
        case .manual:
            return CompanionL10n.text("Manual")
        }
    }
}

struct CompanionAIQuickAction: Identifiable, Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case resultTitle
        case systemPrompt
        case isCustom
        case isPinned
        case sortIndex
        case updatedAt
    }

    var id: String
    var title: String
    var resultTitle: String
    var systemPrompt: String
    var isCustom: Bool
    var isPinned: Bool = false
    var sortIndex: Int = 0
    var updatedAt: Date = Date()

    private static let customPlaceholder = "{{text}}"

    init(
        id: String,
        title: String,
        resultTitle: String,
        systemPrompt: String,
        isCustom: Bool,
        isPinned: Bool = false,
        sortIndex: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.resultTitle = resultTitle
        self.systemPrompt = systemPrompt
        self.isCustom = isCustom
        self.isPinned = isPinned
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        resultTitle = try container.decodeIfPresent(String.self, forKey: .resultTitle) ?? CompanionL10n.text("Result")
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func withPinned(_ pinned: Bool) -> CompanionAIQuickAction {
        var copy = self
        copy.isPinned = pinned
        return copy
    }

    static let translate = CompanionAIQuickAction(
        id: "translate",
        title: CompanionL10n.text("Translate"),
        resultTitle: CompanionL10n.text("Translation"),
        systemPrompt: "",
        isCustom: false
    )

    static let summarize = CompanionAIQuickAction(
        id: "summarize",
        title: CompanionL10n.text("Summarize"),
        resultTitle: CompanionL10n.text("Summary"),
        systemPrompt: """
        You summarize selected text for a busy desktop user. Reply in the user's language. Keep the answer concise, structured, and faithful to the source. Do not add unsupported claims.
        """,
        isCustom: false
    )

    static let polish = CompanionAIQuickAction(
        id: "polish",
        title: CompanionL10n.text("Polish"),
        resultTitle: CompanionL10n.text("Polished Text"),
        systemPrompt: """
        You polish selected writing while preserving its meaning. Reply only with the polished version, in the same language as the source unless the user clearly asks otherwise. Keep names, numbers, links, code, and formatting intact.
        """,
        isCustom: false
    )

    static let friendlyRewrite = CompanionAIQuickAction(
        id: "friendlyRewrite",
        title: CompanionL10n.text("Rewrite"),
        resultTitle: CompanionL10n.text("Rewritten Text"),
        systemPrompt: """
        Rewrite the selected text into a warmer, clearer, more polite tone. Keep the language of the source text. Reply only with the rewritten text.
        """,
        isCustom: false
    )

    static let explainCode = CompanionAIQuickAction(
        id: "explainCode",
        title: CompanionL10n.text("Explain Code"),
        resultTitle: CompanionL10n.text("Code Explanation"),
        systemPrompt: """
        Explain the selected code or technical text clearly. Reply in the user's language. Focus on what it does, important flow, inputs/outputs, and likely risks. Keep it concise unless the code is complex.
        """,
        isCustom: false
    )

    static let draftReply = CompanionAIQuickAction(
        id: "draftReply",
        title: CompanionL10n.text("Draft Reply"),
        resultTitle: CompanionL10n.text("Reply Draft"),
        systemPrompt: """
        Draft a practical reply to the selected message. Reply in the same language as the selected message. Keep it natural, concise, and ready to send. Do not wrap the answer in quotes.
        """,
        isCustom: false
    )

    static let builtInActions: [CompanionAIQuickAction] = [
        .translate,
        .summarize,
        .polish,
        .friendlyRewrite,
        .explainCode,
        .draftReply
    ]

    var usesTextPlaceholder: Bool {
        systemPrompt.contains(Self.customPlaceholder)
    }

    func customUserPrompt(for text: String) -> String {
        if usesTextPlaceholder {
            return systemPrompt.replacingOccurrences(of: Self.customPlaceholder, with: text)
        }
        return """
        \(systemPrompt)

        Selected text:
        \(text)
        """
    }

    static func custom(title: String, prompt: String) -> CompanionAIQuickAction {
        CompanionAIQuickAction(
            id: "custom-\(UUID().uuidString)",
            title: title,
            resultTitle: CompanionL10n.text("Result"),
            systemPrompt: prompt,
            isCustom: true
        )
    }

    static func builtInAction(id: String?) -> CompanionAIQuickAction? {
        guard let id else { return nil }
        return builtInActions.first { $0.id == id }
    }
}

final class CompanionAIService {
    typealias ProviderResolver = () throws -> CompanionAIProviderConfiguration
    typealias ProviderDisplayNameResolver = () -> String

    private enum CompletionEndpoint: String {
        case responses
        case chatCompletions = "chat/completions"
    }

    private struct EndpointCacheKey: Hashable {
        var baseURL: String
        var model: String
        var endpoint: String
    }

    private struct ProviderEndpointPreferenceKey: Hashable {
        var baseURL: String
        var model: String
    }

    private let providerResolver: ProviderResolver
    private let providerDisplayNameResolver: ProviderDisplayNameResolver?
    private let urlSession: URLSession
    private let endpointCacheLock = NSLock()
    private var endpointURLCache: [EndpointCacheKey: URL] = [:]
    private var endpointPreferenceCache: [ProviderEndpointPreferenceKey: CompletionEndpoint] = [:]

    init(
        providerResolver: @escaping ProviderResolver,
        providerDisplayNameResolver: ProviderDisplayNameResolver? = nil,
        urlSession: URLSession = .shared
    ) {
        self.providerResolver = providerResolver
        self.providerDisplayNameResolver = providerDisplayNameResolver
        self.urlSession = urlSession
    }

    func providerDisplayName() -> String {
        if let providerDisplayNameResolver {
            return providerDisplayNameResolver()
        }
        return (try? providerResolver().name) ?? "Companion AI"
    }

    func chat(messages: [CompanionAIChatMessage]) async throws -> String {
        let provider = try providerResolver()
        let systemPrompt = """
        You are XiaoHuaEr, the user's warm, concise desktop companion inside Companion. Reply naturally in the user's language. Keep answers helpful and brief unless the user asks for detail.
        """
        return try await complete(provider: provider, systemPrompt: systemPrompt, messages: messages)
    }

    func testConnection() async throws -> String {
        let provider = try providerResolver()
        _ = try await complete(
            provider: provider,
            systemPrompt: "Reply with OK only.",
            messages: [CompanionAIChatMessage(role: .user, text: "Ping")]
        )
        return "\(provider.name) · \(provider.model)"
    }

    func translate(text: String) async throws -> String {
        let provider = try providerResolver()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let structure = TranslationStructureProtection.protect(text)

        let systemPrompt = """
        You are a precise translation engine. If the source text is mostly Chinese, translate it into natural English. Otherwise translate it into natural Simplified Chinese.

        The source text may contain protected line-break markers such as <<<COMPANION_LINE_BREAK_...>>>.
        Preserve every protected marker exactly once, in the same order, without translating, deleting, merging, splitting, quoting, or wrapping it.
        Keep visible structure around each marker unchanged, including blank lines, list markers, Markdown prefixes, and indentation.
        Translate only the natural-language content.
        Return only the translated text, with no explanation.
        """
        let messages = [CompanionAIChatMessage(role: .user, text: structure.protectedText)]
        let translated = try await complete(provider: provider, systemPrompt: systemPrompt, messages: messages)
        return structure.restore(translated)
    }

    func performQuickAction(_ action: CompanionAIQuickAction, text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if action.id == CompanionAIQuickAction.translate.id {
            return try await translate(text: text)
        }

        let provider = try providerResolver()
        let systemPrompt = action.isCustom
            ? "You run the user's saved Companion AI action. Follow the user's prompt exactly, keep the answer concise, and reply in the most appropriate language for the source text."
            : action.systemPrompt
        let userText = action.isCustom ? action.customUserPrompt(for: text) : text
        return try await complete(
            provider: provider,
            systemPrompt: systemPrompt,
            messages: [CompanionAIChatMessage(role: .user, text: userText)]
        )
    }

    func focusReviewSummary(snapshot: CompanionFocusReviewSnapshot) async throws -> String {
        let provider = try providerResolver()
        let systemPrompt = """
        You write a concise daily focus review for the Companion desktop app user.
        Reply in Simplified Chinese unless the user's data is clearly in another language.
        Use only the provided local aggregate data. Do not mention API keys, logs, or hidden implementation details.
        Keep the result warm, practical, and under 180 Chinese characters. Include one useful next-step suggestion.
        """
        return try await complete(
            provider: provider,
            systemPrompt: systemPrompt,
            messages: [CompanionAIChatMessage(role: .user, text: snapshot.providerContextMarkdown)]
        )
    }

    private func complete(provider: CompanionAIProviderConfiguration, systemPrompt: String, messages: [CompanionAIChatMessage]) async throws -> String {
        let preferenceKey = ProviderEndpointPreferenceKey(
            baseURL: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if cachedCompletionEndpoint(for: preferenceKey) == .chatCompletions {
            do {
                let text = try await completeWithChatCompletionsAPI(provider: provider, systemPrompt: systemPrompt, messages: messages)
                rememberCompletionEndpoint(.chatCompletions, for: preferenceKey)
                return text
            } catch let error as CompanionAIRequestError {
                if case .requestFailed(let status, _) = error,
                   Self.shouldFallbackToResponses(forHTTPStatus: status) {
                    return try await completeWithResponsesAndRemember(provider: provider, systemPrompt: systemPrompt, messages: messages, preferenceKey: preferenceKey)
                }
                throw error
            }
        }

        do {
            return try await completeWithResponsesAndRemember(provider: provider, systemPrompt: systemPrompt, messages: messages, preferenceKey: preferenceKey)
        } catch let error as CompanionAIRequestError {
            switch error {
            case .requestFailed(let status, _):
                guard Self.shouldFallbackToChatCompletions(forHTTPStatus: status) else {
                    throw error
                }
                let text = try await completeWithChatCompletionsAPI(provider: provider, systemPrompt: systemPrompt, messages: messages)
                rememberCompletionEndpoint(.chatCompletions, for: preferenceKey)
                return text
            case .invalidResponse, .emptyResponse:
                let text = try await completeWithChatCompletionsAPI(provider: provider, systemPrompt: systemPrompt, messages: messages)
                rememberCompletionEndpoint(.chatCompletions, for: preferenceKey)
                return text
            default:
                throw error
            }
        }
    }

    private func completeWithResponsesAndRemember(
        provider: CompanionAIProviderConfiguration,
        systemPrompt: String,
        messages: [CompanionAIChatMessage],
        preferenceKey: ProviderEndpointPreferenceKey
    ) async throws -> String {
        let text = try await completeWithResponsesAPI(provider: provider, systemPrompt: systemPrompt, messages: messages)
        rememberCompletionEndpoint(.responses, for: preferenceKey)
        return text
    }

    private func completeWithResponsesAPI(provider: CompanionAIProviderConfiguration, systemPrompt: String, messages: [CompanionAIChatMessage]) async throws -> String {
        let input = messages.map { message -> [String: String] in
            [
                "role": message.role.rawValue,
                "content": message.text
            ]
        }
        let body: [String: Any] = [
            "model": provider.model,
            "instructions": systemPrompt,
            "input": input
        ]
        return try await complete(body: body, provider: provider, endpoint: CompletionEndpoint.responses.rawValue)
    }

    private func completeWithChatCompletionsAPI(provider: CompanionAIProviderConfiguration, systemPrompt: String, messages: [CompanionAIChatMessage]) async throws -> String {
        let chatMessages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            + messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = [
            "model": provider.model,
            "messages": chatMessages
        ]
        return try await complete(body: body, provider: provider, endpoint: CompletionEndpoint.chatCompletions.rawValue)
    }

    private func complete(body: [String: Any], provider: CompanionAIProviderConfiguration, endpoint: String) async throws -> String {
        let urls = try endpointURLs(for: provider, endpoint: endpoint)
        let cacheKey = EndpointCacheKey(
            baseURL: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: provider.model.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint
        )
        let orderedURLs = orderedEndpointURLs(urls, cacheKey: cacheKey)
        var lastError: Error?

        for url in orderedURLs {
            do {
                let data = try await postJSON(body, to: url, apiKey: provider.apiKey)
                let text = try extractText(from: data)
                rememberSuccessfulEndpointURL(url, cacheKey: cacheKey)
                return text
            } catch let error as CompanionAIRequestError {
                lastError = error
                if case .requestFailed(let status, _) = error,
                   !Self.shouldTryNextEndpointCandidate(forHTTPStatus: status) {
                    throw error
                }
                continue
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? CompanionAIRequestError.invalidResponse
    }

    private func orderedEndpointURLs(_ urls: [URL], cacheKey: EndpointCacheKey) -> [URL] {
        endpointCacheLock.lock()
        let cachedURL = endpointURLCache[cacheKey]
        endpointCacheLock.unlock()
        guard let cachedURL, urls.contains(cachedURL) else {
            return urls
        }
        return [cachedURL] + urls.filter { $0 != cachedURL }
    }

    private func rememberSuccessfulEndpointURL(_ url: URL, cacheKey: EndpointCacheKey) {
        endpointCacheLock.lock()
        endpointURLCache[cacheKey] = url
        endpointCacheLock.unlock()
    }

    private func cachedCompletionEndpoint(for cacheKey: ProviderEndpointPreferenceKey) -> CompletionEndpoint? {
        endpointCacheLock.lock()
        let endpoint = endpointPreferenceCache[cacheKey]
        endpointCacheLock.unlock()
        return endpoint
    }

    private func rememberCompletionEndpoint(_ endpoint: CompletionEndpoint, for cacheKey: ProviderEndpointPreferenceKey) {
        endpointCacheLock.lock()
        endpointPreferenceCache[cacheKey] = endpoint
        endpointCacheLock.unlock()
    }

    private func endpointURLs(for provider: CompanionAIProviderConfiguration, endpoint: String) throws -> [URL] {
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = try? CompanionProviderBaseURLPolicy.validate(trimmed).url else {
            throw CompanionAIRequestError.invalidBaseURL(trimmed)
        }

        let normalizedEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let existingPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if existingPath.hasSuffix(normalizedEndpoint) {
            return [baseURL]
        }

        var candidates: [URL] = []
        if existingPath.isEmpty {
            candidates.append(baseURL.appendingPathComponent("v1").appendingPathComponent(normalizedEndpoint))
        } else if !existingPath.hasSuffix("v1") && !existingPath.contains("/v1/") {
            candidates.append(baseURL.appendingPathComponent("v1").appendingPathComponent(normalizedEndpoint))
        }

        candidates.append(baseURL.appendingPathComponent(normalizedEndpoint))
        return Self.deduplicated(candidates)
    }

    private func postJSON(_ body: [String: Any], to url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionAIRequestError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CompanionAIRequestError.requestFailed(httpResponse.statusCode, Self.errorMessage(from: data))
        }

        return data
    }

    private func extractText(from data: Data) throws -> String {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw CompanionAIRequestError.invalidResponse
        }

        if let outputText = object["output_text"] as? String {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let output = object["output"] as? [[String: Any]] {
            let parts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else {
                    return []
                }
                return content.compactMap { contentItem in
                    (contentItem["text"] as? String)
                        ?? (contentItem["output_text"] as? String)
                }
            }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        throw CompanionAIRequestError.emptyResponse
    }

    private static func shouldFallbackToChatCompletions(forHTTPStatus status: Int) -> Bool {
        status == 404 || status == 405
    }

    private static func shouldFallbackToResponses(forHTTPStatus status: Int) -> Bool {
        status == 404 || status == 405
    }

    private static func shouldTryNextEndpointCandidate(forHTTPStatus status: Int) -> Bool {
        status == 404 || status == 405
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            output.append(url)
        }
        return output
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? String(describing: error)
        }

        if let message = object["message"] as? String {
            return message
        }

        return ""
    }
}

private struct TranslationStructureProtection {
    let protectedText: String
    private let lineBreaks: [(token: String, value: String)]
    private let tokenPrefix: String

    static func protect(_ text: String) -> TranslationStructureProtection {
        var output = ""
        var lineBreaks: [(token: String, value: String)] = []
        let tokenPrefix = uniqueLineBreakTokenPrefix(for: text)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\r" {
                let nextIndex = text.index(after: index)
                let lineBreak: String
                if nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    lineBreak = "\r\n"
                    index = text.index(after: nextIndex)
                } else {
                    lineBreak = "\r"
                    index = nextIndex
                }

                let token = "\(tokenPrefix)\(String(format: "%04d", lineBreaks.count))>>>"
                output += token
                lineBreaks.append((token, lineBreak))
                continue
            }

            if character == "\n" {
                let token = "\(tokenPrefix)\(String(format: "%04d", lineBreaks.count))>>>"
                output += token
                lineBreaks.append((token, "\n"))
                index = text.index(after: index)
                continue
            }

            output.append(character)
            index = text.index(after: index)
        }

        return TranslationStructureProtection(protectedText: output, lineBreaks: lineBreaks, tokenPrefix: tokenPrefix)
    }

    func restore(_ translatedText: String) -> String {
        guard !lineBreaks.isEmpty else {
            return translatedText
        }

        let replacements = Dictionary(uniqueKeysWithValues: lineBreaks.map { ($0.token, $0.value) })
        let tokenLength = tokenPrefix.count + 7
        var output = ""
        output.reserveCapacity(translatedText.count)
        var index = translatedText.startIndex

        while index < translatedText.endIndex {
            if translatedText[index...].hasPrefix(tokenPrefix) {
                guard let tokenEnd = translatedText.index(index, offsetBy: tokenLength, limitedBy: translatedText.endIndex) else {
                    break
                }
                let candidate = String(translatedText[index..<tokenEnd])
                if let replacement = replacements[candidate] {
                    output.append(replacement)
                }
                index = tokenEnd
                continue
            }

            output.append(translatedText[index])
            index = translatedText.index(after: index)
        }

        return output
    }

    private static func uniqueLineBreakTokenPrefix(for text: String) -> String {
        for _ in 0..<8 {
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let prefix = "<<<COMPANION_LINE_BREAK_\(nonce)_"
            if !text.contains(prefix) {
                return prefix
            }
        }

        return "<<<COMPANION_LINE_BREAK_FALLBACK_"
    }
}
