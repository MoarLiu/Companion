import AppKit
import Foundation

struct PetSkinManifest: Codable {
    var id: String
    var name: String
    var author: String?
    var version: String?
    var spritesheet: String?
    var cellWidth: Int
    var cellHeight: Int
    var columns: Int
    var frameDirectory: String?
    var states: [PetAnimationState]
}

struct PetAnimationState: Codable, Identifiable {
    var id: String
    var row: Int
    var frames: Int
    var fps: Double?
    var folder: String?
}

enum PetSkinOrigin: Equatable {
    case bundled
    case user

    var label: String {
        switch self {
        case .bundled:
            return "内置皮肤"
        case .user:
            return "用户皮肤"
        }
    }

    var sortOrder: Int {
        switch self {
        case .bundled:
            return 0
        case .user:
            return 1
        }
    }
}

struct PetSkinSummary: Identifiable, Equatable {
    var id: String { manifest.id }

    let manifest: PetSkinManifest
    let folderURL: URL
    let origin: PetSkinOrigin

    static func == (left: PetSkinSummary, right: PetSkinSummary) -> Bool {
        left.id == right.id
            && left.folderURL == right.folderURL
            && left.origin == right.origin
    }
}

struct LoadedSkin {
    let manifest: PetSkinManifest
    let folderURL: URL
    let framesByState: [String: [NSImage]]
}

struct PetFrameFolderManifest: Decodable {
    var name: String
    var frameSize: [Int]
    var framesPerAction: Int
    var actions: [PetFrameFolderAction]

    enum CodingKeys: String, CodingKey {
        case name
        case frameSize = "frame_size"
        case framesPerAction = "frames_per_action"
        case actions
    }
}

struct PetFrameFolderAction: Decodable {
    var id: String
    var label: String?
    var file: String?
}

enum PetSkinStoreError: LocalizedError {
    case missingManifest
    case missingSpriteSheet(String)
    case missingFrameDirectory(String)
    case invalidGeometry
    case missingIdleState

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "Skin folder must contain pet.json or manifest.json."
        case .missingSpriteSheet(let filename):
            return "Missing sprite sheet: \(filename)"
        case .missingFrameDirectory(let directory):
            return "Missing frame directory: \(directory)"
        case .invalidGeometry:
            return "Skin geometry must include positive cell size and column count."
        case .missingIdleState:
            return "Skin must define an idle state with at least one frame."
        }
    }
}

enum PetSpriteLoaderError: LocalizedError {
    case unreadableImage(String)
    case missingUsableIdleFrames

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let path):
            return "Could not read sprite sheet at \(path)."
        case .missingUsableIdleFrames:
            return "The skin did not produce usable idle frames."
        }
    }
}
