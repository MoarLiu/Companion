import Combine
import Foundation

final class PetSkinStore: ObservableObject {
    static let xiaoHuaErSkinID = "小花儿"

    @Published private(set) var skins: [PetSkinSummary] = []

    private let fileManager = FileManager.default
    private let environment: [String: String]
    private var dataRootObserver: NSObjectProtocol?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        dataRootObserver = NotificationCenter.default.addObserver(
            forName: CompanionDataRoot.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let dataRootObserver {
            NotificationCenter.default.removeObserver(dataRootObserver)
        }
    }

    func reload() {
        var found: [String: PetSkinSummary] = [:]

        for root in bundledSkinRoots() {
            for summary in readSkins(in: root, origin: .bundled) {
                found[summary.id] = summary
            }
        }

        for root in userSkinRoots() {
            for summary in readSkins(in: root, origin: .user) {
                found[summary.id] = summary
            }
        }

        skins = found.values.sorted { left, right in
            if left.origin.sortOrder == right.origin.sortOrder {
                return left.manifest.name.localizedCaseInsensitiveCompare(right.manifest.name) == .orderedAscending
            }
            return left.origin.sortOrder < right.origin.sortOrder
        }
    }

    func summary(id: String) -> PetSkinSummary? {
        skins.first { $0.id == id }
    }

    func userSkinDirectory() -> URL {
        CompanionDataRoot.currentURL(environment: environment)
            .appendingPathComponent("Skins", isDirectory: true)
            .standardizedFileURL
    }

    @discardableResult
    func createUserSkinDirectoryIfNeeded() throws -> URL {
        let url = userSkinDirectory()
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundledSkinRoots() -> [URL] {
        var roots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appendingPathComponent("Skins", isDirectory: true))
        }

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        roots.append(workingDirectory.appendingPathComponent("assets/Skins", isDirectory: true))

        return roots
    }

    private func userSkinRoots() -> [URL] {
        [userSkinDirectory()]
    }

    private func readSkins(in rootURL: URL, origin: PetSkinOrigin) -> [PetSkinSummary] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        guard let skinFolders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return skinFolders.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return try? readSkin(at: folderURL, origin: origin)
        }
    }

    private func readSkin(at folderURL: URL, origin: PetSkinOrigin) throws -> PetSkinSummary {
        let manifestURL = folderURL.appendingPathComponent("pet.json")
        let legacyManifestURL = folderURL.appendingPathComponent("manifest.json")
        let manifest: PetSkinManifest

        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PetSkinManifest.self, from: data)
        } else if fileManager.fileExists(atPath: legacyManifestURL.path) {
            let data = try Data(contentsOf: legacyManifestURL)
            let frameManifest = try JSONDecoder().decode(PetFrameFolderManifest.self, from: data)
            manifest = try Self.convertFrameFolderManifest(frameManifest, folderURL: folderURL)
        } else {
            throw PetSkinStoreError.missingManifest
        }

        if let spritesheet = manifest.spritesheet {
            let sheetURL = folderURL.appendingPathComponent(spritesheet)
            guard fileManager.fileExists(atPath: sheetURL.path) else {
                throw PetSkinStoreError.missingSpriteSheet(spritesheet)
            }
        } else {
            let frameRootURL = folderURL.appendingPathComponent(manifest.frameDirectory ?? "frames", isDirectory: true)
            guard fileManager.fileExists(atPath: frameRootURL.path) else {
                throw PetSkinStoreError.missingFrameDirectory(frameRootURL.lastPathComponent)
            }
        }

        guard manifest.cellWidth > 0, manifest.cellHeight > 0, manifest.columns > 0 else {
            throw PetSkinStoreError.invalidGeometry
        }

        guard manifest.states.contains(where: { $0.id == "idle" && $0.frames > 0 }) else {
            throw PetSkinStoreError.missingIdleState
        }

        return PetSkinSummary(manifest: manifest, folderURL: folderURL, origin: origin)
    }

    private static func convertFrameFolderManifest(
        _ manifest: PetFrameFolderManifest,
        folderURL: URL
    ) throws -> PetSkinManifest {
        guard manifest.frameSize.count == 2,
              let cellWidth = manifest.frameSize.first,
              let cellHeight = manifest.frameSize.last,
              cellWidth > 0,
              cellHeight > 0 else {
            throw PetSkinStoreError.invalidGeometry
        }

        let states = manifest.actions.map { action in
            PetAnimationState(
                id: stateID(for: action.id),
                row: 0,
                frames: manifest.framesPerAction,
                fps: 8,
                folder: action.id
            )
        }

        let name = folderURL.lastPathComponent.isEmpty ? manifest.name : folderURL.lastPathComponent

        return PetSkinManifest(
            id: safeDirectoryName(for: name),
            name: name,
            author: nil,
            version: nil,
            spritesheet: nil,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: max(manifest.framesPerAction, 1),
            frameDirectory: "frames",
            states: states
        )
    }

    private static func stateID(for legacyActionID: String) -> String {
        switch legacyActionID {
        case "wave":
            return "waving"
        case "jump":
            return "jumping"
        case "think":
            return "review"
        case "work":
            return "running"
        default:
            return legacyActionID
        }
    }

    private static func safeDirectoryName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalized = id.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()

        return normalized.isEmpty ? "skin" : normalized
    }
}
