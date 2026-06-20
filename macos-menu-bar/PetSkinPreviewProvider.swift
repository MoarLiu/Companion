import AppKit
import Foundation

final class PetSkinPreviewProvider: ObservableObject {
    private var idleFrameCache: [String: [NSImage]] = [:]

    func idleFrames(for skin: PetSkinSummary) -> [NSImage] {
        let key = cacheKey(for: skin)
        if let frames = idleFrameCache[key] {
            return frames
        }

        let frames = (try? PetSpriteLoader.loadIdlePreviewFrames(skin)) ?? []
        idleFrameCache[key] = frames
        return frames
    }

    func invalidate() {
        idleFrameCache.removeAll()
    }

    private func cacheKey(for skin: PetSkinSummary) -> String {
        "\(skin.id)|\(skin.folderURL.path)"
    }
}
