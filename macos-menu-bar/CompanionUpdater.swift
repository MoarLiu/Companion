import AppKit
import CryptoKit
import Foundation

struct CompanionUpdateInfo {
    let version: String
    let build: Int?
    let releaseURL: URL
    let dmgURL: URL
    let checksumURL: URL
}

enum CompanionUpdateCheckResult {
    case upToDate(remoteVersion: String, remoteBuild: Int?)
    case updateAvailable(CompanionUpdateInfo)
}

enum CompanionUpdateError: LocalizedError {
    case invalidReleaseResponse
    case missingReleaseAsset
    case invalidChecksum
    case checksumMismatch
    case installLocationNotWritable(URL)
    case installerLaunchFailed
    case networkFailure(details: String, isTLSFailure: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return CompanionL10n.text("Could not read the latest GitHub release.")
        case .missingReleaseAsset:
            return CompanionL10n.text("The latest release does not include the expected macOS arm64 DMG and checksum assets.")
        case .invalidChecksum:
            return CompanionL10n.text("The release checksum file is invalid.")
        case .checksumMismatch:
            return CompanionL10n.text("The downloaded update failed sha256 verification.")
        case .installLocationNotWritable(let url):
            return CompanionL10n.format("Companion cannot update itself in %@ because that folder is not writable. Download the DMG from GitHub Releases or move Companion to a writable Applications folder.", url.path)
        case .installerLaunchFailed:
            return CompanionL10n.text("Could not start the update installer.")
        case .networkFailure(let details, let isTLSFailure):
            let key = isTLSFailure
                ? "Could not connect to GitHub for updates because the TLS connection failed. Check your network, proxy, or VPN, or open GitHub Releases manually. Details: %@"
                : "Could not connect to GitHub for updates. Check your network, proxy, or VPN, or open GitHub Releases manually. Details: %@"
            return CompanionL10n.format(key, details)
        }
    }

    var isNetworkFailure: Bool {
        if case .networkFailure = self {
            return true
        }
        return false
    }
}

final class CompanionUpdateController {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var name: String?
        var body: String?
        var htmlURL: URL
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    private static let defaultGitHubRepository = "MoarLiu/Companion"
    private static let gitHubRepositoryInfoKey = "CompanionGitHubRepository"
    static var releasesURL: URL {
        githubURL(path: "/\(gitHubRepository)/releases")
    }
    private static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(gitHubRepository)/releases/latest")!
    }
    private static var releaseAtomFeedURL: URL {
        githubURL(path: "/\(gitHubRepository)/releases.atom")
    }
    static let retainedUpdateBackupCount = 2
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func checkForUpdate() async throws -> CompanionUpdateCheckResult {
        do {
            return try await checkForUpdateFromGitHubAPI()
        } catch {
            return try await checkForUpdateFromAtomFeed(apiError: error)
        }
    }

    private func checkForUpdateFromGitHubAPI() async throws -> CompanionUpdateCheckResult {
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Companion", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw CompanionUpdateError.invalidReleaseResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let remoteVersion = Self.version(from: release)
        let remoteBuild = Self.build(from: release)
        let localVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let localBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        guard Self.isRemoteVersion(remoteVersion, remoteBuild: remoteBuild, newerThan: localVersion, localBuild: localBuild) else {
            return .upToDate(remoteVersion: remoteVersion, remoteBuild: remoteBuild)
        }

        guard let dmgAsset = release.assets.first(where: { asset in
            asset.name.hasSuffix("-macos-arm64.dmg") && asset.name.hasPrefix("Companion-")
        }) else {
            throw CompanionUpdateError.missingReleaseAsset
        }
        let checksumAsset = release.assets.first { $0.name == "\(dmgAsset.name).sha256" }
            ?? release.assets.first { $0.name.hasSuffix(".dmg.sha256") && $0.name.contains(remoteVersion) }
        guard let checksumAsset else {
            throw CompanionUpdateError.missingReleaseAsset
        }

        return .updateAvailable(CompanionUpdateInfo(
            version: remoteVersion,
            build: remoteBuild,
            releaseURL: release.htmlURL,
            dmgURL: dmgAsset.browserDownloadURL,
            checksumURL: checksumAsset.browserDownloadURL
        ))
    }

    private func checkForUpdateFromAtomFeed(apiError: Error) async throws -> CompanionUpdateCheckResult {
        var request = URLRequest(url: Self.releaseAtomFeedURL)
        request.setValue("application/atom+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Companion", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let feed = String(data: data, encoding: .utf8)
            else {
                throw CompanionUpdateError.invalidReleaseResponse
            }

            let update = try Self.releaseInfo(fromAtomFeed: feed)
            let localVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let localBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            guard Self.isRemoteVersion(update.version, remoteBuild: update.build, newerThan: localVersion, localBuild: localBuild) else {
                return .upToDate(remoteVersion: update.version, remoteBuild: update.build)
            }

            return .updateAvailable(update)
        } catch {
            throw Self.networkFailure(primary: apiError, fallback: error)
        }
    }

    func downloadAndInstall(_ update: CompanionUpdateInfo) async throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let dmgURL = workDirectory.appendingPathComponent("Companion-\(update.version)-macos-arm64.dmg")
        let checksumURL = workDirectory.appendingPathComponent(dmgURL.lastPathComponent + ".sha256")

        try await download(from: update.dmgURL, to: dmgURL)
        try await download(from: update.checksumURL, to: checksumURL)
        try verifyChecksum(dmgURL: dmgURL, checksumURL: checksumURL)
        try launchInstallerScript(dmgURL: dmgURL, update: update)
    }

    private func download(from remoteURL: URL, to destination: URL) async throws {
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw CompanionUpdateError.invalidReleaseResponse
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private func verifyChecksum(dmgURL: URL, checksumURL: URL) throws {
        let checksumText = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expected = checksumText
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first(where: { $0.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil })?
            .lowercased()
        else {
            throw CompanionUpdateError.invalidChecksum
        }
        let data = try Data(contentsOf: dmgURL)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw CompanionUpdateError.checksumMismatch
        }
    }

    private func launchInstallerScript(dmgURL: URL, update: CompanionUpdateInfo) throws {
        let bundleURL = Bundle.main.bundleURL
        let appParent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: appParent.path) else {
            throw CompanionUpdateError.installLocationNotWritable(appParent)
        }

        let backupRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("Update Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backupURL = backupRoot.appendingPathComponent("Companion-\(update.version)-previous-\(Self.timestamp()).app", isDirectory: true)
        try Self.createUpdateBackup(from: bundleURL, to: backupURL)
        try? Self.pruneUpdateBackups(in: backupRoot)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-update-\(UUID().uuidString).sh")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-update-\(UUID().uuidString).log")

        let script = """
        #!/bin/bash
        set -euo pipefail
        DMG="$1"
        APP="$2"
        BACKUP="$3"
        LOG="$4"
        exec >"$LOG" 2>&1
        MOUNT="$(/usr/bin/hdiutil attach -nobrowse -readonly "$DMG" | /usr/bin/awk '/\\/Volumes\\// {for (i=3; i<=NF; i++) {printf "%s%s", (i==3 ? "" : " "), $i}; print ""; exit}')"
        if [[ -z "$MOUNT" ]]; then
          echo "Unable to mount DMG"
          exit 1
        fi
        cleanup() {
          STATUS=$?
          if [[ "$STATUS" -ne 0 && -d "$BACKUP" ]]; then
            echo "Installer failed with status $STATUS; restoring previous Companion.app from backup"
            /bin/rm -rf "$APP" || true
            /usr/bin/ditto --noextattr --noacl "$BACKUP" "$APP" || true
          fi
          /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
          exit "$STATUS"
        }
        trap cleanup EXIT
        if [[ ! -d "$MOUNT/Companion.app" ]]; then
          echo "Companion.app not found in mounted DMG"
          exit 1
        fi
        /usr/bin/codesign --verify --deep --strict "$MOUNT/Companion.app"
        if ! /usr/bin/codesign -dv --verbose=4 "$MOUNT/Companion.app" 2>&1 | /usr/bin/grep -F "Signature=adhoc" >/dev/null; then
          /usr/sbin/spctl --assess --type execute "$MOUNT/Companion.app"
        fi
        if [[ ! -d "$BACKUP" ]]; then
          echo "Prepared backup not found: $BACKUP"
          exit 1
        fi
        if [[ -d "$APP" ]]; then
          /bin/rm -rf "$APP"
        fi
        /usr/bin/ditto --noextattr --noacl "$MOUNT/Companion.app" "$APP"
        /usr/bin/open "$APP"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, dmgURL.path, bundleURL.path, backupURL.path, logURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            throw CompanionUpdateError.installerLaunchFailed
        }
    }

    private static func version(from release: GitHubRelease) -> String {
        let candidates = [release.tagName, release.name].compactMap { $0 }
        if let version = version(fromCandidates: candidates) {
            return version
        }
        return release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func releaseInfo(fromAtomFeed feed: String) throws -> CompanionUpdateInfo {
        guard let entry = firstCapture(in: feed, pattern: #"<entry\b[^>]*>(.*?)</entry>"#, options: [.dotMatchesLineSeparators]) else {
            throw CompanionUpdateError.invalidReleaseResponse
        }

        let link = firstCapture(in: entry, pattern: #"<link\b[^>]*rel="alternate"[^>]*href="([^"]+)""#)
            ?? firstCapture(in: entry, pattern: #"<link\b[^>]*href="([^"]+)""#)
        let title = firstCapture(in: entry, pattern: #"<title>(.*?)</title>"#, options: [.dotMatchesLineSeparators]) ?? ""
        let id = firstCapture(in: entry, pattern: #"<id>(.*?)</id>"#, options: [.dotMatchesLineSeparators]) ?? ""
        let content = firstCapture(in: entry, pattern: #"<content\b[^>]*>(.*?)</content>"#, options: [.dotMatchesLineSeparators]) ?? ""

        guard
            let link,
            let releaseURL = URL(string: decodeHTMLEntities(link))
        else {
            throw CompanionUpdateError.invalidReleaseResponse
        }

        let tag = releaseURL.lastPathComponent
        let plainText = plainText(fromHTMLLikeText: [title, id, content].joined(separator: "\n"))
        guard let version = version(fromCandidates: [tag, title, plainText]) else {
            throw CompanionUpdateError.invalidReleaseResponse
        }

        let dmgName = "Companion-\(version)-macos-arm64.dmg"
        let checksumName = "\(dmgName).sha256"
        guard entry.contains(dmgName) else {
            throw CompanionUpdateError.missingReleaseAsset
        }

        guard
            let dmgURL = releaseAssetURL(tag: tag, name: dmgName),
            let checksumURL = releaseAssetURL(tag: tag, name: checksumName)
        else {
            throw CompanionUpdateError.invalidReleaseResponse
        }

        return CompanionUpdateInfo(
            version: version,
            build: build(fromText: plainText),
            releaseURL: releaseURL,
            dmgURL: dmgURL,
            checksumURL: checksumURL
        )
    }

    private static func version(fromCandidates candidates: [String]) -> String? {
        for candidate in candidates {
            if let match = candidate.range(of: #"\d+(?:\.\d+){1,3}"#, options: .regularExpression) {
                return String(candidate[match])
            }
        }
        return nil
    }

    private static func build(from release: GitHubRelease) -> Int? {
        let text = [release.tagName, release.name, release.body].compactMap { $0 }.joined(separator: "\n")
        return build(fromText: text)
    }

    private static func build(fromText text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bbuild\s*[:#-]?\s*`?(\d+)`?"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let buildRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[buildRange])
    }

    private static func firstCapture(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    private static var gitHubRepository: String {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: gitHubRepositoryInfoKey) as? String,
            ProcessInfo.processInfo.environment["COMPANION_GITHUB_REPOSITORY"],
            defaultGitHubRepository
        ]
        for candidate in candidates {
            if let repository = normalizedGitHubRepository(candidate) {
                return repository
            }
        }
        return defaultGitHubRepository
    }

    private static func normalizedGitHubRepository(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("https://github.com/") {
            value.removeFirst("https://github.com/".count)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasSuffix(".git") {
            value.removeLast(".git".count)
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 2,
              components.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil })
        else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func githubURL(path: String) -> URL {
        URL(string: "https://github.com\(path)")!
    }

    private static func releaseAssetURL(tag: String, name: String) -> URL? {
        URL(string: "https://github.com/\(gitHubRepository)/releases/download/\(tag)/\(name)")
    }

    private static func plainText(fromHTMLLikeText text: String) -> String {
        decodeHTMLEntities(text)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func networkFailure(primary: Error, fallback: Error) -> CompanionUpdateError {
        let details = [
            CompanionL10n.format("GitHub API: %@", errorSummary(primary)),
            CompanionL10n.format("GitHub Releases feed: %@", errorSummary(fallback))
        ].joined(separator: "\n")
        return .networkFailure(details: details, isTLSFailure: isTLSFailure(primary) || isTLSFailure(fallback))
    }

    private static func errorSummary(_ error: Error) -> String {
        if let updateError = error as? CompanionUpdateError,
           case .networkFailure(let details, _) = updateError {
            return details
        }

        return (error as NSError).localizedDescription
    }

    private static func isTLSFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return true
            default:
                break
            }
        }

        let description = (error as NSError).localizedDescription.lowercased()
        return description.contains("tls") || description.contains("ssl")
    }

    static func isRemoteVersion(_ remoteVersion: String, remoteBuild: Int?, newerThan localVersion: String, localBuild: Int?) -> Bool {
        let remoteParts = versionParts(remoteVersion)
        let localParts = versionParts(localVersion)
        let count = max(remoteParts.count, localParts.count)
        for index in 0..<count {
            let remote = index < remoteParts.count ? remoteParts[index] : 0
            let local = index < localParts.count ? localParts[index] : 0
            if remote != local {
                return remote > local
            }
        }
        return (remoteBuild ?? 0) > (localBuild ?? 0)
    }

    static func pruneUpdateBackups(
        in backupRoot: URL,
        keeping limit: Int = retainedUpdateBackupCount,
        fileManager: FileManager = .default
    ) throws {
        let backups = try fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (url: URL, timestamp: String)? in
            guard url.pathExtension == "app",
                  let timestamp = updateBackupTimestamp(from: url),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else {
                return nil
            }
            return (url, timestamp)
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }

        for backup in backups.dropFirst(max(limit, 0)) {
            try fileManager.removeItem(at: backup.url)
        }
    }

    private static func createUpdateBackup(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--noextattr", "--noacl", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompanionUpdateError.installerLaunchFailed
        }
    }

    private static func updateBackupTimestamp(from url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasPrefix("Companion-"),
              name.hasSuffix(".app"),
              let markerRange = name.range(of: "-previous-")
        else {
            return nil
        }

        let timestamp = String(name[markerRange.upperBound..<name.index(name.endIndex, offsetBy: -4)])
        guard timestamp.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return timestamp
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
