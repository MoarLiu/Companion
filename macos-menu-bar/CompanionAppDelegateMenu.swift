import AppKit
import Foundation

extension AppDelegate {
    func configureMenu() {
        mainMenuCoordinator.configureMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        mainMenuCoordinator.menuWillOpen(menu)
    }

    func configureCompanionDataMenu() {
        mainMenuCoordinator.configureCompanionDataMenu()
    }

    func refreshStatus() {
        mainMenuCoordinator.refreshStatus()
    }

    func rebuildTranslationMenu() {
        mainMenuCoordinator.rebuildTranslationMenu()
    }
}
