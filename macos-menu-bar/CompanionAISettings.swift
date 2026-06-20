import AppKit
import Foundation
import SwiftUI

struct CompanionAISettings: Codable, Equatable {
    var version: Int
    var providerName: String
    var baseURL: String
    var model: String
    var secretReference: String

    static let defaultSecretReference = "companion-ai-api-key"

    static let `default` = CompanionAISettings(
        version: 1,
        providerName: "Companion AI",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        secretReference: defaultSecretReference
    )
}

struct CompanionAISettingsSnapshot {
    var settings: CompanionAISettings
    var hasStoredAPIKey: Bool

    var menuSummary: String {
        let name = settings.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasStoredAPIKey {
            return "\(name.isEmpty ? "Companion AI" : name) · \(model.isEmpty ? "No model" : model)"
        }
        return "AI provider not configured"
    }
}

struct CompanionAISettingsInput {
    var providerName: String
    var baseURL: String
    var model: String
    var apiKey: String
}

enum CompanionAISettingsError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL(String)
    case missingModel
    case missingAPIKey
    case corruptSettings(URL)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Companion AI is missing an API Base URL."
        case .invalidBaseURL(let value):
            return "Companion AI has an invalid API Base URL: \(CompanionProviderBaseURLPolicy.errorMessage(for: value))"
        case .missingModel:
            return "Companion AI is missing a model."
        case .missingAPIKey:
            return "Companion AI is missing an API Key. Open AI Settings and paste a key first."
        case .corruptSettings(let url):
            return "Companion AI settings are corrupt: \(url.path)"
        }
    }
}

final class CompanionAISettingsStore {
    static let fileName = "ai-settings.json"
    static let credentialFileName = "ai-credentials.json"

    private let environment: [String: String]
    private let fileManager: FileManager
    private let credentialStore: CompanionAssetUploadCredentialStoring
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        credentialStore: CompanionAssetUploadCredentialStoring? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.credentialStore = credentialStore ?? CompanionLocalCredentialStore(
            fileName: Self.credentialFileName,
            environment: environment,
            fileManager: fileManager
        )
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    var url: URL {
        CompanionDataRoot.currentURL(environment: environment).appendingPathComponent(Self.fileName)
    }

    func snapshot() throws -> CompanionAISettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let settings = try load()
        return CompanionAISettingsSnapshot(
            settings: settings,
            hasStoredAPIKey: try hasAPIKey(reference: settings.secretReference)
        )
    }

    func save(_ input: CompanionAISettingsInput) throws {
        lock.lock()
        defer { lock.unlock() }

        let current = try load()
        let providerName = input.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = input.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = input.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretReference = current.secretReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompanionAISettings.defaultSecretReference
            : current.secretReference

        guard !baseURL.isEmpty else {
            throw CompanionAISettingsError.missingBaseURL
        }
        guard (try? CompanionProviderBaseURLPolicy.validate(baseURL)) != nil else {
            throw CompanionAISettingsError.invalidBaseURL(baseURL)
        }
        guard !model.isEmpty else {
            throw CompanionAISettingsError.missingModel
        }

        if apiKey.isEmpty {
            guard try hasAPIKey(reference: secretReference) else {
                throw CompanionAISettingsError.missingAPIKey
            }
        } else {
            try credentialStore.saveSecret(apiKey, reference: secretReference)
        }

        let settings = CompanionAISettings(
            version: 1,
            providerName: providerName.isEmpty ? CompanionAISettings.default.providerName : providerName,
            baseURL: baseURL,
            model: model,
            secretReference: secretReference
        )
        try save(settings)
    }

    func providerConfiguration() throws -> CompanionAIProviderConfiguration {
        lock.lock()
        defer { lock.unlock() }

        let settings = try load()
        let providerName = settings.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = settings.secretReference.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty else {
            throw CompanionAISettingsError.missingBaseURL
        }
        guard (try? CompanionProviderBaseURLPolicy.validate(baseURL)) != nil else {
            throw CompanionAISettingsError.invalidBaseURL(baseURL)
        }
        guard !model.isEmpty else {
            throw CompanionAISettingsError.missingModel
        }
        guard !reference.isEmpty,
              let apiKey = try credentialStore.secret(reference: reference)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw CompanionAISettingsError.missingAPIKey
        }

        return CompanionAIProviderConfiguration(
            name: providerName.isEmpty ? CompanionAISettings.default.providerName : providerName,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model
        )
    }

    func displayName() -> String {
        let name = (try? snapshot().settings.providerName.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return name.isEmpty ? CompanionAISettings.default.providerName : name
    }

    private func hasAPIKey(reference: String) throws -> Bool {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let secret = try credentialStore.secret(reference: reference)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret?.isEmpty == false
    }

    private func load() throws -> CompanionAISettings {
        guard fileManager.fileExists(atPath: url.path) else {
            return .default
        }
        do {
            return try decoder.decode(CompanionAISettings.self, from: Data(contentsOf: url))
        } catch {
            throw CompanionAISettingsError.corruptSettings(url)
        }
    }

    private func save(_ settings: CompanionAISettings) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum CompanionAISettingsPanel {
    static func run(snapshot: CompanionAISettingsSnapshot) -> CompanionAISettingsInput? {
        var result: CompanionAISettingsInput?
        let response = CompanionGlassModalHost.runModal(width: 520, fallbackHeight: 470, title: "Companion AI Settings") {
            CompanionAISettingsPanelView(snapshot: snapshot) { input in
                result = input
                NSApp.stopModal(withCode: .OK)
            } onCancel: {
                NSApp.stopModal(withCode: .cancel)
            }
        }
        return response == .OK ? result : nil
    }
}

private struct CompanionAISettingsPanelView: View {
    let snapshot: CompanionAISettingsSnapshot
    let onSave: (CompanionAISettingsInput) -> Void
    let onCancel: () -> Void

    @State private var providerName: String
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var statusMessage = ""
    @State private var statusTone: CompanionFormStatusTone = .neutral

    init(
        snapshot: CompanionAISettingsSnapshot,
        onSave: @escaping (CompanionAISettingsInput) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onSave = onSave
        self.onCancel = onCancel
        _providerName = State(initialValue: snapshot.settings.providerName)
        _baseURL = State(initialValue: snapshot.settings.baseURL)
        _model = State(initialValue: snapshot.settings.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CompanionModalHeader(
                icon: "sparkles",
                title: "Companion AI",
                message: "Configure the lightweight provider used by XiaoHuaEr chat, translation, quick actions, and focus review."
            )

            VStack(alignment: .leading, spacing: 12) {
                field("Provider Name") {
                    TextField("Companion AI", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                }
                field("API Base URL") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                field("Model") {
                    TextField("gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                field("API Key") {
                    SecureField(
                        snapshot.hasStoredAPIKey ? "Leave blank to keep stored key" : "Paste API key",
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(statusTone.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CompanionModalFieldLabel(text: title)
            content()
        }
    }

    private func submit() {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty else {
            setStatus("Fill API Base URL before saving.", .error)
            return
        }
        guard (try? CompanionProviderBaseURLPolicy.validate(trimmedBaseURL)) != nil else {
            setStatus(CompanionProviderBaseURLPolicy.errorMessage(for: trimmedBaseURL), .error)
            return
        }
        guard !trimmedModel.isEmpty else {
            setStatus("Fill Model before saving.", .error)
            return
        }
        guard snapshot.hasStoredAPIKey || !trimmedAPIKey.isEmpty else {
            setStatus("Paste API Key before saving.", .error)
            return
        }

        onSave(CompanionAISettingsInput(
            providerName: providerName,
            baseURL: trimmedBaseURL,
            model: trimmedModel,
            apiKey: trimmedAPIKey
        ))
    }

    private func setStatus(_ message: String, _ tone: CompanionFormStatusTone) {
        statusMessage = message
        statusTone = tone
    }
}
