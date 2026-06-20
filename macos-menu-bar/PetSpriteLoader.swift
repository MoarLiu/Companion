import AppKit
import Foundation
import ImageIO

enum PetSpriteLoader {
    static func load(_ summary: PetSkinSummary) throws -> LoadedSkin {
        let manifest = summary.manifest
        if let spritesheet = manifest.spritesheet {
            return try loadSpriteSheet(summary, spritesheet: spritesheet)
        }

        return try loadFrameFolders(summary)
    }

    static func loadIdlePreviewFrames(_ summary: PetSkinSummary) throws -> [NSImage] {
        let manifest = summary.manifest
        guard let idle = manifest.states.first(where: { $0.id == "idle" && $0.frames > 0 }) else {
            throw PetSpriteLoaderError.missingUsableIdleFrames
        }

        if let spritesheet = manifest.spritesheet {
            return try loadSpriteSheetFrames(summary, spritesheet: spritesheet, state: idle)
        }

        let frameRootURL = summary.folderURL.appendingPathComponent(
            manifest.frameDirectory ?? "frames",
            isDirectory: true
        )
        let folderName = idle.folder ?? idle.id
        let stateFolderURL = frameRootURL.appendingPathComponent(folderName, isDirectory: true)
        let images = try frameImageURLs(in: stateFolderURL)
            .prefix(idle.frames)
            .compactMap { NSImage(contentsOf: $0) }

        guard !images.isEmpty else {
            throw PetSpriteLoaderError.missingUsableIdleFrames
        }

        return images
    }

    private static func loadSpriteSheet(_ summary: PetSkinSummary, spritesheet: String) throws -> LoadedSkin {
        let manifest = summary.manifest

        var framesByState: [String: [NSImage]] = [:]
        for state in manifest.states where state.frames > 0 {
            let frames = try loadSpriteSheetFrames(summary, spritesheet: spritesheet, state: state)
            if !frames.isEmpty {
                framesByState[state.id] = frames
            }
        }

        guard framesByState["idle"]?.isEmpty == false else {
            throw PetSpriteLoaderError.missingUsableIdleFrames
        }

        return LoadedSkin(manifest: manifest, folderURL: summary.folderURL, framesByState: framesByState)
    }

    private static func loadSpriteSheetFrames(
        _ summary: PetSkinSummary,
        spritesheet: String,
        state: PetAnimationState
    ) throws -> [NSImage] {
        let manifest = summary.manifest
        let sheetURL = summary.folderURL.appendingPathComponent(spritesheet)

        guard let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetSpriteLoaderError.unreadableImage(sheetURL.path)
        }

        let frameCount = min(state.frames, manifest.columns)
        var frames: [NSImage] = []
        for column in 0..<frameCount {
            let rect = CGRect(
                x: column * manifest.cellWidth,
                y: state.row * manifest.cellHeight,
                width: manifest.cellWidth,
                height: manifest.cellHeight
            )

            guard let cropped = sheet.cropping(to: rect) else {
                continue
            }

            frames.append(NSImage(
                cgImage: cropped,
                size: NSSize(width: manifest.cellWidth, height: manifest.cellHeight)
            ))
        }

        return frames
    }

    private static func loadFrameFolders(_ summary: PetSkinSummary) throws -> LoadedSkin {
        let manifest = summary.manifest
        let frameRootURL = summary.folderURL.appendingPathComponent(
            manifest.frameDirectory ?? "frames",
            isDirectory: true
        )
        var framesByState: [String: [NSImage]] = [:]

        for state in manifest.states where state.frames > 0 {
            let folderName = state.folder ?? state.id
            let stateFolderURL = frameRootURL.appendingPathComponent(folderName, isDirectory: true)
            let imageURLs = try frameImageURLs(in: stateFolderURL).prefix(state.frames)
            let frames = imageURLs.compactMap { NSImage(contentsOf: $0) }

            if !frames.isEmpty {
                framesByState[state.id] = frames
            }
        }

        guard framesByState["idle"]?.isEmpty == false else {
            throw PetSpriteLoaderError.missingUsableIdleFrames
        }

        return LoadedSkin(manifest: manifest, folderURL: summary.folderURL, framesByState: framesByState)
    }

    private static func frameImageURLs(in folderURL: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { ["png", "webp", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { left, right in
                left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
    }
}
