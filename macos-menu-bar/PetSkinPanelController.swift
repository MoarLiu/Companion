import AppKit
import Combine
import SwiftUI

final class PetSkinPanelController {
    private var window: NSWindow?
    private let viewModel: PetSkinPanelViewModel

    init(
        skinStore: PetSkinStore,
        selectedSkinIDProvider: @escaping () -> String?,
        selectSkinAction: @escaping (String) -> Void,
        reloadAction: @escaping () -> Void,
        openUserSkinFolderAction: @escaping () throws -> URL
    ) {
        viewModel = PetSkinPanelViewModel(
            skinStore: skinStore,
            selectedSkinIDProvider: selectedSkinIDProvider,
            selectSkinAction: selectSkinAction,
            reloadAction: reloadAction,
            openUserSkinFolderAction: openUserSkinFolderAction
        )
    }

    func show() {
        viewModel.refreshSelectedSkin()
        let window = existingOrNewWindow()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateSelectedSkinID(_ id: String?) {
        viewModel.setSelectedSkinID(id)
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window {
            return window
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "桌面宠物皮肤"
        window.minSize = NSSize(width: 680, height: 460)
        window.contentView = CompanionInteractiveHostingView(rootView: PetSkinPanelView(viewModel: viewModel))
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }
}

final class PetSkinPanelViewModel: ObservableObject {
    @Published private(set) var skins: [PetSkinSummary]
    @Published private(set) var selectedSkinID: String?
    @Published var errorMessage: String?

    let previewProvider = PetSkinPreviewProvider()

    private let skinStore: PetSkinStore
    private let selectedSkinIDProvider: () -> String?
    private let selectSkinAction: (String) -> Void
    private let reloadAction: () -> Void
    private let openUserSkinFolderAction: () throws -> URL
    private var cancellables = Set<AnyCancellable>()

    init(
        skinStore: PetSkinStore,
        selectedSkinIDProvider: @escaping () -> String?,
        selectSkinAction: @escaping (String) -> Void,
        reloadAction: @escaping () -> Void,
        openUserSkinFolderAction: @escaping () throws -> URL
    ) {
        self.skinStore = skinStore
        self.selectedSkinIDProvider = selectedSkinIDProvider
        self.selectSkinAction = selectSkinAction
        self.reloadAction = reloadAction
        self.openUserSkinFolderAction = openUserSkinFolderAction
        skins = skinStore.skins
        selectedSkinID = selectedSkinIDProvider()

        skinStore.$skins
            .receive(on: RunLoop.main)
            .sink { [weak self] skins in
                self?.skins = skins
            }
            .store(in: &cancellables)
    }

    func setSelectedSkinID(_ id: String?) {
        selectedSkinID = id
    }

    func refreshSelectedSkin() {
        selectedSkinID = selectedSkinIDProvider()
    }

    func select(_ skin: PetSkinSummary) {
        errorMessage = nil
        selectSkinAction(skin.id)
        refreshSelectedSkin()
    }

    func reloadSkins() {
        errorMessage = nil
        previewProvider.invalidate()
        reloadAction()
        skins = skinStore.skins
        refreshSelectedSkin()
    }

    func openUserSkinFolder() {
        do {
            let url = try openUserSkinFolderAction()
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
