import AppKit
import Foundation

final class CompanionAssetUploadSettingsCoordinator {
    var onStatusTitleChanged: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let profileStore: CompanionAssetUploadProfileStore
    private let historyStore: CompanionAssetUploadHistoryStore
    private let finderApprovalStore: CompanionFinderAssetUploadApprovalStore
    private let mcpClientProfilesStore: MCPClientProfilesStore

    init(
        profileStore: CompanionAssetUploadProfileStore,
        historyStore: CompanionAssetUploadHistoryStore,
        finderApprovalStore: CompanionFinderAssetUploadApprovalStore,
        mcpClientProfilesStore: MCPClientProfilesStore
    ) {
        self.profileStore = profileStore
        self.historyStore = historyStore
        self.finderApprovalStore = finderApprovalStore
        self.mcpClientProfilesStore = mcpClientProfilesStore
    }

    func openHistory() {
        let historyURL = historyStore.url
        if FileManager.default.fileExists(atPath: historyURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([historyURL])
        } else {
            NSWorkspace.shared.open(CompanionDataRoot.currentURL())
        }
    }

    func copyResult(id: String) {
        guard let record = historyStore.recent(limit: 100).first(where: { $0.assetID == id }) else {
            return
        }
        let formatted = record.formatted?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = formatted?.isEmpty == false ? (formatted ?? "") : (record.url ?? "")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearHistory() {
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Clear Asset Upload History?"),
            informativeText: CompanionL10n.text("Companion will remove local upload summaries. Remote uploaded objects and profile settings are not changed."),
            primaryButtonTitle: CompanionL10n.text("Clear"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        historyStore.clear()
    }

    func deleteProfile() {
        let profile: CompanionAssetUploadProfile
        do {
            profile = try profileStore.defaultProfile(requireCredentials: false)
        } catch {
            onError?(error.localizedDescription)
            return
        }
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Delete Asset Upload Profile?"),
            informativeText: CompanionL10n.format("Companion will delete \"%@\", remove its local credentials, and revoke related stored approvals. Remote uploaded objects are not changed.", profile.name),
            primaryButtonTitle: CompanionL10n.text("Delete"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        do {
            let deleted = try profileStore.deleteProfile(id: profile.id)
            revokeApprovals(for: deleted.id)
            onStatusTitleChanged?(Self.statusTitle("Deleted %@", deleted.name))
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Asset Upload Profile Deleted"),
                informativeText: CompanionL10n.text("Related stored upload approvals were revoked."),
                tone: .success
            )
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func testProfile() {
        let profile: CompanionAssetUploadProfile
        do {
            profile = try profileStore.defaultProfile(requireCredentials: false)
        } catch {
            if case CompanionAssetUploadProfileStoreError.noDefaultProfile = error {
                showSettings()
            } else {
                onError?(error.localizedDescription)
            }
            return
        }

        do {
            let service = CompanionAssetUploadService(profileStore: profileStore)
            let result = try service.testProfile(profileID: profile.id)
            let output = result.formatted ?? result.url ?? ""
            let detail: String
            let tone: CompanionAlertTone
            switch result.cleanupStatus {
            case .notNeeded:
                detail = CompanionL10n.format("Dry-run URL:\n%@", output)
                tone = .success
            case .deleted:
                detail = CompanionL10n.format("Probe upload succeeded and the test object was deleted.\n\nResult:\n%@", output)
                tone = .success
            case .warning:
                let warning = result.cleanupWarning ?? CompanionL10n.text("Probe cleanup did not complete. You may need to delete the test object manually.")
                detail = CompanionL10n.format("Probe upload succeeded, but cleanup needs attention:\n%@\n\nResult:\n%@", warning, output)
                tone = .warning
            }
            CompanionNonBlockingAlert.present(
                messageText: result.didWriteProbe
                    ? CompanionL10n.text("Asset Upload Profile Tested")
                    : CompanionL10n.text("Asset Upload Profile Looks Ready"),
                informativeText: detail,
                tone: tone
            )
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func clearApprovals() {
        guard CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Clear Legacy Finder Upload Approvals?"),
            informativeText: CompanionL10n.text("Companion will remove approval records created by older Finder upload flows. Upload profiles and history are not changed."),
            primaryButtonTitle: CompanionL10n.text("Clear"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .warning
        ) else {
            return
        }
        finderApprovalStore.revokeAll()
        CompanionNonBlockingAlert.present(
            messageText: CompanionL10n.text("Legacy Finder upload approvals cleared"),
            informativeText: CompanionL10n.text("Finder right-click upload now uses the system Services action directly."),
            tone: .success
        )
    }

    func showSettings() {
        let current = try? profileStore.defaultProfile(requireCredentials: false)
        guard let target = chooseProfileType(current: current) else {
            return
        }

        switch target {
        case .s3Compatible:
            showS3Settings(current: current)
        case .customHTTP:
            let httpProfile = current?.type == .customHTTP ? current : nil
            guard let input = CompanionProviderProfilePanels.showAssetUploadCustomHTTPProfile(initialProfile: httpProfile) else {
                return
            }
            let profile = CompanionAssetUploadProfile(
                id: current?.id ?? "default-http",
                type: .customHTTP,
                name: input.name,
                enabled: true,
                s3: nil,
                customHTTP: CompanionAssetUploadProfile.CustomHTTPConfig(
                    uploadURL: input.uploadURL,
                    method: input.method,
                    bodyMode: input.bodyMode,
                    fileFieldName: input.fileFieldName,
                    additionalHeaders: input.additionalHeaders,
                    sensitiveHeaderReferences: httpProfile?.customHTTP?.sensitiveHeaderReferences,
                    responseURLJSONPath: input.responseURLJSONPath,
                    publicBaseURL: input.publicBaseURL.isEmpty ? nil : input.publicBaseURL
                ),
                limits: CompanionAssetUploadProfile.Limits(
                    maxSizeBytes: input.maxSizeMB * 1024 * 1024,
                    allowedMimeTypes: nil
                ),
                defaultOutputFormat: input.defaultOutputFormat,
                createdAt: current?.createdAt ?? Date(),
                lastUsedAt: current?.lastUsedAt
            )
            do {
                try profileStore.upsert(profile, makeDefault: true)
                revokeApprovals(for: profile.id)
                onStatusTitleChanged?(Self.statusTitle("Asset upload configured"))
                CompanionNonBlockingAlert.present(
                    messageText: CompanionL10n.text("Asset Upload Configured"),
                    informativeText: CompanionL10n.text("companion.asset.upload will use this Custom HTTP target. Finder upload requires an S3-compatible default profile."),
                    tone: .success
                )
            } catch {
                onStatusTitleChanged?(Self.statusTitle("Asset upload config failed"))
                onError?(error.localizedDescription)
            }
        }
    }

    func showS3Settings() {
        showS3Settings(current: try? profileStore.defaultProfile(requireCredentials: false))
    }

    private func showS3Settings(current: CompanionAssetUploadProfile?) {
        let s3Profile = current?.type == .s3Compatible ? current : nil
        let currentCredentials = s3Profile.flatMap { try? profileStore.credentials(for: $0) }
        guard let input = CompanionProviderProfilePanels.showAssetUploadS3Profile(
            initialProfile: s3Profile,
            initialCredentials: currentCredentials
        ) else {
            return
        }
        let profile = CompanionAssetUploadProfile(
            id: s3Profile?.id ?? "default-s3",
            type: .s3Compatible,
            name: input.name,
            enabled: true,
            s3: CompanionAssetUploadProfile.S3Config(
                endpoint: input.endpoint,
                region: input.region,
                bucket: input.bucket,
                pathPrefix: input.pathPrefix,
                publicBaseURL: input.publicBaseURL.isEmpty ? nil : input.publicBaseURL,
                usePathStyle: input.usePathStyle,
                credentialReference: s3Profile?.s3?.credentialReference,
                accessKeyID: nil,
                secretAccessKey: nil
            ),
            customHTTP: nil,
            limits: CompanionAssetUploadProfile.Limits(
                maxSizeBytes: input.maxSizeMB * 1024 * 1024,
                allowedMimeTypes: nil
            ),
            defaultOutputFormat: input.defaultOutputFormat,
            createdAt: s3Profile?.createdAt ?? Date(),
            lastUsedAt: s3Profile?.lastUsedAt
        )
        do {
            let credentials: CompanionAssetUploadS3Credentials?
            if input.secretAccessKey.isEmpty, let currentCredentials, currentCredentials.accessKeyID == input.accessKeyID {
                credentials = nil
            } else {
                credentials = CompanionAssetUploadS3Credentials(accessKeyID: input.accessKeyID, secretAccessKey: input.secretAccessKey)
            }
            try profileStore.upsert(profile, makeDefault: true, credentials: credentials)
            revokeApprovals(for: profile.id)
            onStatusTitleChanged?(Self.statusTitle("Asset upload configured"))
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Asset Upload Configured"),
                informativeText: CompanionL10n.text("Finder right-click upload will use this S3-compatible target."),
                tone: .success
            )
        } catch {
            onStatusTitleChanged?(Self.statusTitle("Asset upload config failed"))
            onError?(error.localizedDescription)
        }
    }

    private func chooseProfileType(current: CompanionAssetUploadProfile?) -> CompanionAssetUploadProfileType? {
        let currentSummary = current.map { CompanionL10n.format("Current default: %@", $0.profileSummary) }
            ?? CompanionL10n.text("No asset upload profile is configured. Choose a target type to open its setup form.")
        let choice = CompanionNonBlockingAlert.choose(
            messageText: CompanionL10n.text("Choose Asset Upload Target"),
            informativeText: currentSummary,
            primaryButtonTitle: CompanionL10n.text("S3-compatible"),
            secondaryButtonTitle: CompanionL10n.text("Custom HTTP"),
            cancelButtonTitle: CompanionL10n.text("Cancel"),
            tone: .info
        )
        switch choice {
        case .primary:
            return .s3Compatible
        case .secondary:
            return .customHTTP
        case .cancel:
            return nil
        }
    }

    private func revokeApprovals(for profileID: String) {
        finderApprovalStore.revoke(profileID: profileID)
        mcpClientProfilesStore.revokeAssetUpload(profileID: profileID)
    }

    private static func statusTitle(_ key: String, _ arguments: CVarArg...) -> String {
        let message = String(format: CompanionL10n.text(key), arguments: arguments)
        return CompanionL10n.format("Status: %@", message)
    }
}
