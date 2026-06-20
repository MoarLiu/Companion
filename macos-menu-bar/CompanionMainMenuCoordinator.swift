import AppKit
import Foundation

final class CompanionMainMenuCoordinator {
    unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
    }

    func configureMenu() {
        app.menu.delegate = app
        app.menu.removeAllItems()

        app.versionItem.title = AppDelegate.versionTitle()
        app.versionItem.isEnabled = false
        app.menu.addItem(app.versionItem)

        app.statusItemText.isEnabled = false
        app.menu.addItem(app.statusItemText)
        app.menu.addItem(NSMenuItem(
            title: CompanionL10n.text("Dashboard"),
            action: #selector(AppDelegate.showSettingsStatusCenterAction),
            keyEquivalent: ","
        ))
        app.menu.addItem(NSMenuItem.separator())

        app.desktopPet.appendMenuItems(to: app.menu)
        app.menu.addItem(NSMenuItem.separator())

        app.companionDataItem.submenu = app.companionDataMenu
        configureCompanionDataMenu()
        app.menu.addItem(app.companionDataItem)
        app.menu.addItem(NSMenuItem.separator())

        app.menu.addItem(NSMenuItem(
            title: CompanionL10n.text("Check Update"),
            action: #selector(AppDelegate.checkUpdateAction),
            keyEquivalent: ""
        ))
        app.menu.addItem(NSMenuItem.separator())
        app.menu.addItem(NSMenuItem(
            title: CompanionL10n.text("Quit Companion"),
            action: #selector(AppDelegate.quitAction),
            keyEquivalent: "q"
        ))
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === app.menu else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(app.lastMenuRefreshAt) >= app.menuRefreshInterval else {
            refreshStatus()
            return
        }
        app.lastMenuRefreshAt = now
        configureMenu()
        refreshStatus()
    }

    func configureCompanionDataMenu() {
        app.companionDataMenu.removeAllItems()
        for item in [
            app.exportDataPackageItem,
            app.importDataPackageItem,
            NSMenuItem.separator(),
            app.assetUploadSettingsItem,
            NSMenuItem.separator(),
            app.toggleICloudStorageItem,
            app.openCompanionDataFolderItem,
            app.openICloudDataFolderItem,
            NSMenuItem.separator(),
            app.exportDiagnosticPackageItem
        ] {
            app.companionDataMenu.addItem(item)
        }

        for item in [
            app.exportDataPackageItem,
            app.importDataPackageItem,
            app.assetUploadSettingsItem,
            app.exportDiagnosticPackageItem,
            app.toggleICloudStorageItem,
            app.openCompanionDataFolderItem,
            app.openICloudDataFolderItem
        ] {
            item.target = app
        }

        app.toggleICloudStorageItem.title = app.dataPackageController.isICloudStorageEnabled()
            ? CompanionL10n.text("Move Data Back to This Mac")
            : CompanionL10n.text("Store Data in iCloud")
        app.toggleICloudStorageItem.state = app.dataPackageController.isICloudStorageEnabled() ? .on : .off
    }

    func refreshStatus() {
        if let countdown = app.menuBarCountdownTitle, !countdown.isEmpty {
            app.statusItemText.title = AppDelegate.statusTitle(countdown)
            app.statusItem.button?.toolTip = countdown
            return
        }

        app.statusItemText.title = AppDelegate.statusTitle("Ready")
        app.statusItem.button?.toolTip = CompanionL10n.text("Companion")
    }

    func rebuildTranslationMenu() {
        app.clipboardTranslation.refreshSelectionPopupState()
        app.translationMenu.removeAllItems()
        app.translationItem.title = CompanionL10n.text("AI Quick Actions")
        app.translationMenu.title = CompanionL10n.text("AI Quick Actions")

        app.companionAIStatusItem.title = (try? app.companionAISettingsStore.snapshot().menuSummary)
            ?? CompanionL10n.text("AI provider not configured")
        app.companionAIStatusItem.isEnabled = false
        app.translationMenu.addItem(app.companionAIStatusItem)

        app.companionAISettingsItem.target = app
        app.translationMenu.addItem(app.companionAISettingsItem)

        app.testCompanionAIConnectionItem.target = app
        app.translationMenu.addItem(app.testCompanionAIConnectionItem)
        app.translationMenu.addItem(NSMenuItem.separator())

        app.clipboardTranslationItem.target = app
        app.clipboardTranslationItem.title = CompanionL10n.text("Clipboard AI Popup")
        app.clipboardTranslationItem.state = app.clipboardTranslation.isClipboardEnabled ? .on : .off
        app.translationMenu.addItem(app.clipboardTranslationItem)

        app.selectionTranslationItem.target = app
        app.selectionTranslationItem.state = app.clipboardTranslation.isSelectionEnabled ? .on : .off
        app.selectionTranslationItem.title = app.clipboardTranslation.accessibilityPermissionGranted
            ? CompanionL10n.text("Selected Text AI Popup")
            : CompanionL10n.text("Selected Text AI Popup (Needs Permission)")
        app.translationMenu.addItem(app.selectionTranslationItem)

        app.accessibilityPermissionItem.target = app
        app.accessibilityPermissionItem.title = app.clipboardTranslation.accessibilityPermissionGranted
            ? CompanionL10n.text("Accessibility Permission: Granted")
            : CompanionL10n.text("Grant Accessibility Permission")
        app.accessibilityPermissionItem.isEnabled = !app.clipboardTranslation.accessibilityPermissionGranted
        app.translationMenu.addItem(app.accessibilityPermissionItem)
        app.translationMenu.addItem(NSMenuItem.separator())

        app.translateClipboardItem.target = app
        app.translateClipboardItem.title = CompanionL10n.text("Process Clipboard")
        app.translationMenu.addItem(app.translateClipboardItem)

        app.uploadClipboardImageItem.target = app
        app.uploadClipboardImageItem.title = CompanionL10n.text("Upload Clipboard Image")
        app.uploadClipboardImageItem.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        app.translationMenu.addItem(app.uploadClipboardImageItem)
    }
}
