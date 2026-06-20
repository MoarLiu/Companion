import AppKit
import Foundation
import SwiftUI

extension AppDelegate {
    @objc func refreshStatusAction() {
        refreshStatus()
    }

    func showError(_ message: String) {
        CompanionNonBlockingAlert.present(
            messageText: CompanionL10n.text("Companion Error"),
            informativeText: message,
            tone: .warning
        )
    }

    @objc func checkUpdateAction() {
        statusItemText.title = Self.statusTitle("Checking for updates...")

        Task {
            do {
                let result = try await updateController.checkForUpdate()
                await MainActor.run {
                    switch result {
                    case .upToDate(let version, let build):
                        let buildText = build.map { " (\($0))" } ?? ""
                        statusItemText.title = Self.statusTitle("Companion is up to date")
                        CompanionNonBlockingAlert.present(
                            messageText: CompanionL10n.text("Companion is up to date"),
                            informativeText: CompanionL10n.format("Latest release: %@.", "\(version)\(buildText)"),
                            tone: .success
                        )
                    case .updateAvailable(let update):
                        presentUpdatePrompt(update)
                    }
                }
            } catch {
                await MainActor.run {
                    NSSound.beep()
                    statusItemText.title = Self.statusTitle("Update check failed")
                    showUpdateCheckError(error)
                }
            }
        }
    }

    func showUpdateCheckError(_ error: Error) {
        guard
            let updateError = error as? CompanionUpdateError,
            updateError.isNetworkFailure
        else {
            showError(error.localizedDescription)
            return
        }

        let choice = CompanionNonBlockingAlert.choose(
            messageText: CompanionL10n.text("Update check failed"),
            informativeText: error.localizedDescription,
            primaryButtonTitle: CompanionL10n.text("Open GitHub Releases"),
            cancelButtonTitle: CompanionL10n.text("OK"),
            tone: .warning
        )
        if choice == .primary {
            NSWorkspace.shared.open(CompanionUpdateController.releasesURL)
        }
    }

    func presentUpdatePrompt(_ update: CompanionUpdateInfo) {
        let buildText = update.build.map { " (\($0))" } ?? ""
        let choice = CompanionNonBlockingAlert.choose(
            messageText: CompanionL10n.text("Update Available"),
            informativeText: CompanionL10n.format("Companion %@ is available. Companion can download, verify, and install the update now.", "\(update.version)\(buildText)"),
            primaryButtonTitle: CompanionL10n.text("Download and Install"),
            secondaryButtonTitle: CompanionL10n.text("Open GitHub Releases"),
            tone: .info
        )

        switch choice {
        case .primary:
            installUpdate(update)
        case .secondary:
            NSWorkspace.shared.open(update.releaseURL)
        case .cancel:
            statusItemText.title = Self.statusTitle("Update canceled")
        }
    }

    func installUpdate(_ update: CompanionUpdateInfo) {
        statusItemText.title = Self.statusTitle("Downloading update...")
        Task {
            do {
                try await updateController.downloadAndInstall(update)
            } catch {
                await MainActor.run {
                    NSSound.beep()
                    statusItemText.title = Self.statusTitle("Update failed")
                    showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func exportDataPackageAction() {
        guard confirmSensitiveDataPackageExport() else {
            return
        }

        let panel = NSSavePanel()
        panel.title = CompanionL10n.text("Export Companion Data Package")
        panel.nameFieldStringValue = dataPackageController.defaultDataPackageURL().lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        statusItemText.title = Self.statusTitle("Exporting Companion data...")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.dataPackageController.exportDataPackage(to: destination)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self.statusItemText.title = Self.statusTitle("Exported Companion data package")
                    CompanionNonBlockingAlert.present(
                        messageText: CompanionL10n.text("Companion Data Exported"),
                        informativeText: url.path,
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = Self.statusTitle("Export failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func importDataPackageAction() {
        let panel = NSOpenPanel()
        panel.title = CompanionL10n.text("Import Companion Data Package")
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let packageURL = panel.url else {
            return
        }
        guard confirmDataPackageImport() else {
            return
        }

        statusItemText.title = Self.statusTitle("Importing Companion data...")
        // 在搬移数据前同步 flush 有延迟落盘的 store（日记），避免丢失最后一次编辑。
        NotificationCenter.default.post(name: CompanionDataRoot.willChangeNotification, object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.dataPackageController.importDataPackage(from: packageURL)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let rollbackURL):
                    self.refreshStatus()
                    NotificationCenter.default.post(name: CompanionDataRoot.didChangeNotification, object: nil)
                    self.statusItemText.title = Self.statusTitle("Imported Companion data package")
                    CompanionNonBlockingAlert.present(
                        messageText: CompanionL10n.text("Companion Data Imported"),
                        informativeText: CompanionL10n.format("Rollback package: %@\nRestart Companion if any window still shows old data.", rollbackURL.path),
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = Self.statusTitle("Import failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func exportDiagnosticPackageAction() {
        let panel = NSSavePanel()
        panel.title = CompanionL10n.text("Export Diagnostic Package")
        panel.nameFieldStringValue = dataPackageController.defaultDiagnosticPackageURL().lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        statusItemText.title = Self.statusTitle("Exporting diagnostics...")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.dataPackageController.exportDiagnosticPackage(to: destination)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self.statusItemText.title = Self.statusTitle("Exported diagnostics")
                    CompanionNonBlockingAlert.present(
                        messageText: CompanionL10n.text("Diagnostic Package Exported"),
                        informativeText: url.path,
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = Self.statusTitle("Diagnostic export failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func showAssetUploadSettingsAction() {
        assetUploadSettingsCoordinator.showSettings()
    }

    func showAssetUploadS3SettingsAction() {
        assetUploadSettingsCoordinator.showS3Settings()
    }

    @objc func toggleICloudStorageAction() {
        let enabled = dataPackageController.isICloudStorageEnabled()
        guard confirmICloudStorageChange(enabling: !enabled) else {
            return
        }

        statusItemText.title = enabled ? Self.statusTitle("Moving Companion data to this Mac...") : Self.statusTitle("Moving Companion data to iCloud...")
        // 在搬移数据前同步 flush 有延迟落盘的 store（日记），避免丢失最后一次编辑。
        NotificationCenter.default.post(name: CompanionDataRoot.willChangeNotification, object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                if enabled {
                    return try self.dataPackageController.disableICloudStorage()
                }
                return try self.dataPackageController.enableICloudStorage()
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let rollbackURL):
                    self.configureCompanionDataMenu()
                    NotificationCenter.default.post(name: CompanionDataRoot.didChangeNotification, object: nil)
                    self.statusItemText.title = enabled ? Self.statusTitle("Companion data moved to this Mac") : Self.statusTitle("Companion data stored in iCloud")
                    CompanionNonBlockingAlert.present(
                        messageText: enabled ? CompanionL10n.text("Companion Data Moved to This Mac") : CompanionL10n.text("Companion Data Stored in iCloud"),
                        informativeText: CompanionL10n.format("Rollback package: %@\nRestart Companion if any window still shows old data.", rollbackURL.path),
                        tone: .success
                    )
                case .failure(let error):
                    NSSound.beep()
                    self.statusItemText.title = Self.statusTitle("iCloud data move failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func openCompanionDataFolderAction() {
        dataPackageController.openCompanionHome()
    }

    @objc func openICloudDataFolderAction() {
        dataPackageController.openICloudCompanionHome()
    }

    func confirmSensitiveDataPackageExport() -> Bool {
        CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Export Companion Data Package?"),
            informativeText: CompanionL10n.text("This package contains your full Companion data folder, including AI settings, local credentials, Journal, reminders, Pomodoro records, and workflow history. Store it only in a trusted place."),
            primaryButtonTitle: CompanionL10n.text("Export"),
            tone: .warning
        )
    }

    func confirmDataPackageImport() -> Bool {
        CompanionNonBlockingAlert.confirm(
            messageText: CompanionL10n.text("Import Companion Data Package?"),
            informativeText: CompanionL10n.text("Importing replaces the current Companion data folder. Companion will create a rollback package first."),
            primaryButtonTitle: CompanionL10n.text("Import"),
            tone: .warning
        )
    }

    func confirmICloudStorageChange(enabling: Bool) -> Bool {
        CompanionNonBlockingAlert.confirm(
            messageText: enabling ? CompanionL10n.text("Store Companion Data in iCloud?") : CompanionL10n.text("Move Companion Data Back to This Mac?"),
            informativeText: enabling
                ? CompanionL10n.text("If iCloud Drive/Companion already has Companion data, Companion will use that existing iCloud folder and will not overwrite it. If it is empty, Companion will copy the current ~/.companion contents there. AI settings, local credentials, Journal, reminders, Pomodoro, and AI history may be stored in iCloud.")
                : CompanionL10n.text("Companion will copy iCloud Drive/Companion back to ~/.companion, then use the local folder as its data folder."),
            primaryButtonTitle: enabling ? CompanionL10n.text("Use iCloud") : CompanionL10n.text("Use This Mac"),
            tone: .warning
        )
    }

    @objc func quitAction() {
        NSApp.terminate(nil)
    }

    @objc func toggleClipboardTranslationAction(_ sender: NSMenuItem) {
        if clipboardTranslation.isClipboardEnabled {
            clipboardTranslation.stop()
        } else {
            clipboardTranslation.start()
        }

        rebuildTranslationMenu()
    }

    @objc func toggleSelectionTranslationAction(_ sender: NSMenuItem) {
        if clipboardTranslation.isSelectionEnabled {
            clipboardTranslation.stopSelectionPopup()
        } else {
            clipboardTranslation.startSelectionPopup()
        }

        rebuildTranslationMenu()
    }

    @objc func requestAccessibilityPermissionAction() {
        clipboardTranslation.requestAccessibilityPermission()
        rebuildTranslationMenu()
    }

    @objc func showCompanionAISettingsAction() {
        do {
            let snapshot = try companionAISettingsStore.snapshot()
            guard let input = CompanionAISettingsPanel.run(snapshot: snapshot) else {
                return
            }
            try companionAISettingsStore.save(input)
            rebuildTranslationMenu()
            statusItemText.title = Self.statusTitle("Companion AI settings saved")
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc func testCompanionAIConnectionAction() {
        statusItemText.title = Self.statusTitle("Testing Companion AI...")
        Task {
            do {
                let summary = try await aiService.testConnection()
                await MainActor.run {
                    self.statusItemText.title = Self.statusTitle("Companion AI ready: %@", summary)
                    self.rebuildTranslationMenu()
                }
            } catch {
                await MainActor.run {
                    self.statusItemText.title = Self.statusTitle("Companion AI failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func translateClipboardAction() {
        clipboardTranslation.translateClipboardNow()
    }

    @objc func uploadClipboardImageAction() {
        uploadClipboardImageToClipboard()
    }
}
