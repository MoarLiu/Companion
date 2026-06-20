import AVFoundation
import Combine
import Foundation

struct DesktopPetMusicTrack: Equatable, Hashable, Identifiable {
    let id: Int
    let title: String
    let artistNames: [String]
    let albumTitle: String?
    let coverImageURL: URL?
    let sourceTitle: String?

    init(
        id: Int,
        title: String,
        artistNames: [String] = [],
        albumTitle: String? = nil,
        coverImageURL: URL? = nil,
        sourceTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistNames = artistNames
        self.albumTitle = albumTitle
        self.coverImageURL = coverImageURL
        self.sourceTitle = sourceTitle
    }

    var externalPlaybackURL: URL {
        Self.externalPlaybackURL(forSongID: id)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "曲目 \(id)" : trimmed
    }

    var displayArtist: String {
        let artists = artistNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !artists.isEmpty {
            return artists.joined(separator: "、")
        }
        if let sourceTitle, !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceTitle
        }
        return "未知歌手"
    }

    func mergingMetadata(from detail: DesktopPetMusicTrack) -> DesktopPetMusicTrack {
        DesktopPetMusicTrack(
            id: id,
            title: detail.displayTitle,
            artistNames: detail.artistNames.isEmpty ? artistNames : detail.artistNames,
            albumTitle: detail.albumTitle ?? albumTitle,
            coverImageURL: detail.coverImageURL ?? coverImageURL,
            sourceTitle: sourceTitle ?? detail.sourceTitle
        )
    }

    static func externalPlaybackURL(forSongID id: Int) -> URL {
        URL(string: "https://music.163.com/song/media/outer/url?id=\(id)")!
    }

    static func preferredHTTPSPlaybackURL(from url: URL) -> URL {
        guard
            url.scheme == "http",
            let host = url.host,
            host == "music.126.net" || host.hasSuffix(".music.126.net"),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    static func isPlayableExternalRedirectURL(_ url: URL?) -> Bool {
        guard
            let url,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(),
            host == "music.126.net" || host.hasSuffix(".music.126.net")
        else {
            return false
        }
        return true
    }
}

enum DesktopPetMusicPlaybackStatus: Equatable {
    case idle
    case loadingCatalog
    case resolvingTrack
    case playing
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "待播放"
        case .loadingCatalog:
            return "正在加载歌池"
        case .resolvingTrack:
            return "正在解析音源"
        case .playing:
            return "正在播放"
        case .stopped:
            return "已停止"
        case .failed:
            return "播放失败"
        }
    }

    var isBusy: Bool {
        switch self {
        case .loadingCatalog, .resolvingTrack:
            return true
        case .idle, .playing, .stopped, .failed:
            return false
        }
    }

    var isPlaying: Bool {
        self == .playing
    }
}

struct DesktopPetMusicPlayerSnapshot: Equatable {
    var status: DesktopPetMusicPlaybackStatus = .idle
    var currentTrack: DesktopPetMusicTrack?
    var catalog: [DesktopPetMusicTrack] = []
    var canPlayPrevious = false

    var canPlayNext: Bool {
        !catalog.isEmpty
    }

    var playableCount: Int {
        catalog.count
    }
}

struct DesktopPetMusicPlaylistSource: Equatable, Hashable {
    let id: Int
    let name: String
    let coverImageURL: URL?

    var detailURL: URL {
        URL(string: "https://music.163.com/api/v6/playlist/detail?id=\(id)&s=0")!
    }

    // Mirrors YesPlayMusic's static byAppleMusic playlist list.
    static let byAppleMusic: [DesktopPetMusicPlaylistSource] = [
        DesktopPetMusicPlaylistSource(
            id: 5278068783,
            name: "Happy Hits",
            coverImageURL: URL(string: "https://p2.music.126.net/GvYQoflE99eoeGi9jG4Bsw==/109951165375336156.jpg")
        ),
        DesktopPetMusicPlaylistSource(
            id: 5277771961,
            name: "中嘻合璧",
            coverImageURL: URL(string: "https://p2.music.126.net/5CJeYN35LnzRDsv5Lcs0-Q==/109951165374966765.jpg")
        ),
        DesktopPetMusicPlaylistSource(
            id: 5277965913,
            name: "Heartbreak Pop",
            coverImageURL: URL(string: "https://p1.music.126.net/cPaBXr1wZSg86ddl47AK7Q==/109951165375130918.jpg")
        ),
        DesktopPetMusicPlaylistSource(
            id: 5277969451,
            name: "Festival Bangers",
            coverImageURL: URL(string: "https://p2.music.126.net/FDtX55P2NjccDna-LBj9PA==/109951165375065973.jpg")
        ),
        DesktopPetMusicPlaylistSource(
            id: 5277778542,
            name: "Bedtime Beats",
            coverImageURL: URL(string: "https://p2.music.126.net/hC0q2dGbOWHVfg4nkhIXPg==/109951165374881177.jpg")
        )
    ]

    // Mirrors YesPlayMusic's fixed home-page chart playlist ids.
    static let yesPlayMusicHomeCharts: [DesktopPetMusicPlaylistSource] = [
        DesktopPetMusicPlaylistSource(id: 19723756, name: "飙升榜", coverImageURL: nil),
        DesktopPetMusicPlaylistSource(id: 180106, name: "UK排行榜周榜", coverImageURL: nil),
        DesktopPetMusicPlaylistSource(id: 60198, name: "美国Billboard榜", coverImageURL: nil),
        DesktopPetMusicPlaylistSource(id: 3812895, name: "Beatport全球电子舞曲榜", coverImageURL: nil),
        DesktopPetMusicPlaylistSource(id: 60131, name: "日本Oricon榜", coverImageURL: nil)
    ]

    static let defaultSources: [DesktopPetMusicPlaylistSource] = byAppleMusic + yesPlayMusicHomeCharts
}

enum DesktopPetMusicToggleResult: Equatable {
    case starting
    case started(DesktopPetMusicTrack)
    case stopped
    case unavailable
}

final class DesktopPetMusicFeature: ObservableObject {
    static let defaultTargetCatalogSize = 500

    @Published private(set) var snapshot = DesktopPetMusicPlayerSnapshot()

    var onPlaybackFailed: ((DesktopPetMusicTrack?, String) -> Void)?
    var onPlaybackAdvanced: ((DesktopPetMusicTrack) -> Void)?
    var onPlaybackStarted: ((DesktopPetMusicTrack) -> Void)?

    private let playlistSources: [DesktopPetMusicPlaylistSource]
    private let targetCatalogSize: Int
    private let maximumRetries = 3
    private var player: AVPlayer?
    private var catalog: [DesktopPetMusicTrack] = []
    private var shuffledQueue: [DesktopPetMusicTrack] = []
    private var playedHistory: [DesktopPetMusicTrack] = []
    private var currentTrack: DesktopPetMusicTrack?
    private var currentPlaybackID: UUID?
    private var playbackStatus: DesktopPetMusicPlaybackStatus = .idle
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var urlResolver: DesktopPetMusicURLResolver?
    private var playlistTrackResolver: DesktopPetMusicPlaylistTrackResolver?
    private var retryCount = 0

    init(
        playlistSources: [DesktopPetMusicPlaylistSource] = DesktopPetMusicPlaylistSource.defaultSources,
        targetCatalogSize: Int = DesktopPetMusicFeature.defaultTargetCatalogSize
    ) {
        self.playlistSources = playlistSources
        self.targetCatalogSize = max(targetCatalogSize, 1)
    }

    deinit {
        stopInternal()
    }

    var hasActivePlayback: Bool {
        currentPlaybackID != nil || player != nil || urlResolver != nil || playlistTrackResolver != nil
    }

    @discardableResult
    func toggleRandomPlayback() -> DesktopPetMusicToggleResult {
        if hasActivePlayback {
            stop()
            return .stopped
        }

        return startRandomPlayback()
    }

    @discardableResult
    func startRandomPlayback() -> DesktopPetMusicToggleResult {
        if let track = nextTrack(excluding: nil) {
            retryCount = 0
            play(track, recordHistory: false)
            return .started(track)
        }

        guard !playlistSources.isEmpty else {
            updateSnapshot(status: .failed("没有可用歌单。"))
            return .unavailable
        }

        preparePlaylistCatalogAndPlay()
        return .starting
    }

    @discardableResult
    func playPreviousTrack() -> DesktopPetMusicToggleResult {
        guard let previousTrack = playedHistory.popLast() else {
            return startRandomPlayback()
        }
        if let currentTrack, currentTrack != previousTrack {
            shuffledQueue.insert(currentTrack, at: 0)
        }
        retryCount = 0
        onPlaybackAdvanced?(previousTrack)
        play(previousTrack, recordHistory: false)
        return .started(previousTrack)
    }

    @discardableResult
    func playNextTrack() -> DesktopPetMusicToggleResult {
        guard let nextTrack = nextTrack(excluding: currentTrack) else {
            return startRandomPlayback()
        }
        retryCount = 0
        onPlaybackAdvanced?(nextTrack)
        play(nextTrack, recordHistory: true)
        return .started(nextTrack)
    }

    @discardableResult
    func playTrack(_ track: DesktopPetMusicTrack) -> DesktopPetMusicToggleResult {
        guard catalog.contains(where: { $0.id == track.id }) else {
            return .unavailable
        }
        shuffledQueue.removeAll { $0.id == track.id }
        retryCount = 0
        onPlaybackStarted?(track)
        play(track, recordHistory: true)
        return .started(track)
    }

    private func preparePlaylistCatalogAndPlay() {
        let playbackID = UUID()
        currentPlaybackID = playbackID
        retryCount = 0
        updateSnapshot(status: .loadingCatalog)

        let resolver = DesktopPetMusicPlaylistTrackResolver()
        playlistTrackResolver = resolver
        resolver.loadTracks(from: playlistSources, targetCount: targetCatalogSize) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.currentPlaybackID == playbackID else { return }
                self.playlistTrackResolver = nil

                switch result {
                case .success(let tracks):
                    self.catalog = tracks
                    self.shuffledQueue = []
                    self.playedHistory = []
                    guard let track = self.nextTrack(excluding: nil) else {
                        let message = "默认歌单没有可播放曲目。"
                        self.stopInternal(status: .failed(message))
                        self.onPlaybackFailed?(nil, message)
                        return
                    }
                    self.onPlaybackStarted?(track)
                    self.play(track, recordHistory: false)
                case .failure(let error):
                    self.stopInternal(status: .failed(error.localizedDescription))
                    self.onPlaybackFailed?(nil, error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        stopInternal(status: .stopped)
    }

    private func stopInternal(status: DesktopPetMusicPlaybackStatus = .stopped) {
        currentPlaybackID = nil
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        urlResolver?.cancel()
        urlResolver = nil
        playlistTrackResolver?.cancel()
        playlistTrackResolver = nil
        player?.pause()
        player = nil
        currentTrack = nil
        retryCount = 0
        updateSnapshot(status: status)
    }

    private func play(_ track: DesktopPetMusicTrack, recordHistory: Bool) {
        if recordHistory, let currentTrack, currentTrack != track {
            playedHistory.append(currentTrack)
            if playedHistory.count > 80 {
                playedHistory.removeFirst(playedHistory.count - 80)
            }
        }

        let playbackID = UUID()
        currentPlaybackID = playbackID
        currentTrack = track
        updateSnapshot(status: .resolvingTrack)
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        urlResolver?.cancel()
        urlResolver = nil

        let resolver = DesktopPetMusicURLResolver()
        urlResolver = resolver
        resolver.resolve(track.externalPlaybackURL) { [weak self] resolvedURL in
            DispatchQueue.main.async {
                guard let self, self.currentPlaybackID == playbackID else { return }
                self.urlResolver = nil
                self.startPlayer(track: track, playbackID: playbackID, url: resolvedURL ?? track.externalPlaybackURL)
            }
        }
    }

    private func startPlayer(track: DesktopPetMusicTrack, playbackID: UUID, url: URL) {
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "Mozilla/5.0",
                    "Referer": "https://music.163.com/"
                ]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0.45

        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            guard let self,
                  self.currentPlaybackID == playbackID,
                  item === observedItem
            else {
                return
            }

            if observedItem.status == .failed {
                DispatchQueue.main.async {
                    self.handlePlaybackFailure(
                        track: track,
                        message: observedItem.error?.localizedDescription ?? "网易云外链暂时无法播放。"
                    )
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.advanceAfterNaturalEnd(from: track, playbackID: playbackID)
        }

        self.player = player
        player.play()
        updateSnapshot(status: .playing)
    }

    private func advanceAfterNaturalEnd(from track: DesktopPetMusicTrack, playbackID: UUID) {
        guard currentPlaybackID == playbackID else { return }
        guard let nextTrack = nextTrack(excluding: track) else {
            stop()
            return
        }

        retryCount = 0
        onPlaybackAdvanced?(nextTrack)
        play(nextTrack, recordHistory: true)
    }

    private func handlePlaybackFailure(track: DesktopPetMusicTrack, message: String) {
        guard hasActivePlayback else { return }

        if retryCount < maximumRetries, let nextTrack = nextTrack(excluding: track) {
            retryCount += 1
            play(nextTrack, recordHistory: false)
            return
        }

        let failedTrack = currentTrack
        stopInternal(status: .failed(message))
        onPlaybackFailed?(failedTrack, message)
    }

    private func nextTrack(excluding excludedTrack: DesktopPetMusicTrack?) -> DesktopPetMusicTrack? {
        guard !catalog.isEmpty else { return nil }
        if shuffledQueue.isEmpty {
            refillQueue(excluding: excludedTrack)
        }
        if shuffledQueue.first == excludedTrack, shuffledQueue.count > 1 {
            shuffledQueue.append(shuffledQueue.removeFirst())
        }
        return shuffledQueue.isEmpty ? nil : shuffledQueue.removeFirst()
    }

    private func refillQueue(excluding excludedTrack: DesktopPetMusicTrack?) {
        shuffledQueue = catalog.shuffled()
        if let excludedTrack, shuffledQueue.first == excludedTrack, shuffledQueue.count > 1 {
            shuffledQueue.append(shuffledQueue.removeFirst())
        }
    }

    private func updateSnapshot(status: DesktopPetMusicPlaybackStatus? = nil) {
        if let status {
            playbackStatus = status
        }
        snapshot = DesktopPetMusicPlayerSnapshot(
            status: playbackStatus,
            currentTrack: currentTrack,
            catalog: catalog,
            canPlayPrevious: !playedHistory.isEmpty
        )
    }
}

private enum DesktopPetMusicPlaylistError: LocalizedError {
    case noTracks

    var errorDescription: String? {
        switch self {
        case .noTracks:
            return "无法从默认歌单加载曲目。"
        }
    }
}

private final class DesktopPetMusicPlaylistTrackResolver {
    private let lock = NSLock()
    private var session: URLSession?
    private var playableTrackFilter: DesktopPetMusicPlayableTrackFilter?
    private var trackDetailResolver: DesktopPetMusicTrackDetailResolver?
    private var isCancelled = false

    func loadTracks(
        from sources: [DesktopPetMusicPlaylistSource],
        targetCount: Int,
        completion: @escaping (Result<[DesktopPetMusicTrack], Error>) -> Void
    ) {
        guard !sources.isEmpty else {
            completion(.failure(DesktopPetMusicPlaylistError.noTracks))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        let session = URLSession(configuration: configuration)
        self.session = session

        let group = DispatchGroup()
        let resultLock = NSLock()
        var tracksBySource = Array(repeating: [DesktopPetMusicTrack](), count: sources.count)

        for (index, source) in sources.enumerated() {
            group.enter()
            var request = URLRequest(url: source.detailURL)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

            session.dataTask(with: request) { [weak self] data, _, _ in
                defer { group.leave() }
                guard self?.cancelled() == false,
                      let data,
                      let response = try? JSONDecoder().decode(PlaylistDetailResponse.self, from: data),
                      response.code == 200,
                      let playlist = response.playlist
                else {
                    return
                }

                let sourceTitle = playlist.name ?? source.name
                var detailsByID: [Int: DesktopPetMusicTrack] = [:]
                for summary in playlist.tracks ?? [] {
                    detailsByID[summary.id] = summary.musicTrack(sourceTitle: sourceTitle)
                }
                let tracks = playlist.trackIds.map { trackID in
                    detailsByID[trackID.id] ?? DesktopPetMusicTrack(
                        id: trackID.id,
                        title: "曲目 \(trackID.id)",
                        sourceTitle: sourceTitle
                    )
                }
                resultLock.lock()
                tracksBySource[index] = tracks
                resultLock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.cancelled() == false else { return }
            session.finishTasksAndInvalidate()
            self.session = nil

            var seen = Set<Int>()
            let candidates = tracksBySource
                .flatMap { $0 }
                .filter { track in
                    seen.insert(track.id).inserted
                }

            guard !candidates.isEmpty else {
                completion(.failure(DesktopPetMusicPlaylistError.noTracks))
                return
            }

            let filter = DesktopPetMusicPlayableTrackFilter()
            self.setPlayableTrackFilter(filter)
            filter.filter(candidates, targetCount: targetCount) { [weak self, weak filter] playableTracks in
                guard let self, self.cancelled() == false else { return }
                if let filter {
                    self.clearPlayableTrackFilter(filter)
                }

                guard !playableTracks.isEmpty else {
                    completion(.failure(DesktopPetMusicPlaylistError.noTracks))
                    return
                }

                let detailResolver = DesktopPetMusicTrackDetailResolver()
                self.setTrackDetailResolver(detailResolver)
                detailResolver.enrich(playableTracks) { [weak self, weak detailResolver] enrichedTracks in
                    guard let self, self.cancelled() == false else { return }
                    if let detailResolver {
                        self.clearTrackDetailResolver(detailResolver)
                    }
                    completion(.success(enrichedTracks))
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let filter = playableTrackFilter
        let detailResolver = trackDetailResolver
        playableTrackFilter = nil
        trackDetailResolver = nil
        lock.unlock()
        session?.invalidateAndCancel()
        session = nil
        filter?.cancel()
        detailResolver?.cancel()
    }

    private func cancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private func setPlayableTrackFilter(_ filter: DesktopPetMusicPlayableTrackFilter) {
        lock.lock()
        playableTrackFilter = filter
        lock.unlock()
    }

    private func clearPlayableTrackFilter(_ filter: DesktopPetMusicPlayableTrackFilter) {
        lock.lock()
        if playableTrackFilter === filter {
            playableTrackFilter = nil
        }
        lock.unlock()
    }

    private func setTrackDetailResolver(_ resolver: DesktopPetMusicTrackDetailResolver) {
        lock.lock()
        trackDetailResolver = resolver
        lock.unlock()
    }

    private func clearTrackDetailResolver(_ resolver: DesktopPetMusicTrackDetailResolver) {
        lock.lock()
        if trackDetailResolver === resolver {
            trackDetailResolver = nil
        }
        lock.unlock()
    }

    private struct PlaylistDetailResponse: Decodable {
        let code: Int?
        let playlist: Playlist?
    }

    private struct Playlist: Decodable {
        let name: String?
        let trackIds: [TrackID]
        let tracks: [DesktopPetMusicTrackSummary]?
    }

    private struct TrackID: Decodable {
        let id: Int
    }
}

private struct DesktopPetMusicTrackSummary: Decodable {
    let id: Int
    let name: String?
    private let ar: [Artist]?
    private let artists: [Artist]?
    private let al: Album?
    private let album: Album?

    func musicTrack(sourceTitle: String?) -> DesktopPetMusicTrack {
        let artistNames = (ar ?? artists ?? []).map(\.name).filter { !$0.isEmpty }
        let albumInfo = al ?? album
        return DesktopPetMusicTrack(
            id: id,
            title: name ?? "曲目 \(id)",
            artistNames: artistNames,
            albumTitle: albumInfo?.name,
            coverImageURL: albumInfo?.picUrl,
            sourceTitle: sourceTitle
        )
    }

    private struct Artist: Decodable {
        let name: String
    }

    private struct Album: Decodable {
        let name: String?
        let picUrl: URL?
    }
}

private final class DesktopPetMusicTrackDetailResolver {
    private let lock = NSLock()
    private var session: URLSession?
    private var isCancelled = false

    func enrich(_ tracks: [DesktopPetMusicTrack], completion: @escaping ([DesktopPetMusicTrack]) -> Void) {
        guard !tracks.isEmpty else {
            completion([])
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 18
        let session = URLSession(configuration: configuration)
        self.session = session

        let batches = stride(from: 0, to: tracks.count, by: 80).map { start in
            Array(tracks[start..<min(start + 80, tracks.count)])
        }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var detailTracksByID: [Int: DesktopPetMusicTrack] = [:]

        for batch in batches {
            guard let url = Self.detailURL(for: batch.map(\.id)) else { continue }
            group.enter()
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

            session.dataTask(with: request) { [weak self] data, _, _ in
                defer { group.leave() }
                guard self?.cancelled() == false,
                      let data,
                      let response = try? JSONDecoder().decode(SongDetailResponse.self, from: data)
                else {
                    return
                }

                let details = response.songs.map { $0.musicTrack(sourceTitle: nil) }
                resultLock.lock()
                for detail in details {
                    detailTracksByID[detail.id] = detail
                }
                resultLock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard self?.cancelled() == false else { return }
            session.finishTasksAndInvalidate()
            self?.session = nil

            let enriched = tracks.map { track in
                guard let detail = detailTracksByID[track.id] else { return track }
                return track.mergingMetadata(from: detail)
            }
            completion(enriched)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        session?.invalidateAndCancel()
        session = nil
    }

    private func cancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private static func detailURL(for ids: [Int]) -> URL? {
        var components = URLComponents(string: "https://music.163.com/api/song/detail")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: "[\(ids.map(String.init).joined(separator: ","))]")
        ]
        return components?.url
    }

    private struct SongDetailResponse: Decodable {
        let songs: [DesktopPetMusicTrackSummary]
    }
}

private final class DesktopPetMusicPlayableTrackFilter: NSObject, URLSessionTaskDelegate {
    private let stateQueue = DispatchQueue(label: "companion.desktop-pet.music.playability")
    private let maximumConcurrentRequests = 8
    private var session: URLSession?
    private var candidates: [DesktopPetMusicTrack] = []
    private var targetCount = 1
    private var nextIndex = 0
    private var activeTaskCount = 0
    private var playableTracks: [DesktopPetMusicTrack] = []
    private var taskTracks: [Int: DesktopPetMusicTrack] = [:]
    private var redirectURLs: [Int: URL] = [:]
    private var completion: (([DesktopPetMusicTrack]) -> Void)?
    private var isCancelled = false

    func filter(
        _ candidates: [DesktopPetMusicTrack],
        targetCount: Int,
        completion: @escaping ([DesktopPetMusicTrack]) -> Void
    ) {
        stateQueue.async {
            guard !candidates.isEmpty else {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

            self.session = session
            self.candidates = candidates
            self.targetCount = max(targetCount, 1)
            self.completion = completion
            self.startMoreRequests()
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.completion = nil
            self.taskTracks.removeAll()
            self.redirectURLs.removeAll()
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        stateQueue.async {
            self.redirectURLs[task.taskIdentifier] = request.url
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async {
            guard !self.isCancelled, self.completion != nil else { return }
            let track = self.taskTracks.removeValue(forKey: task.taskIdentifier)
            let redirectURL = self.redirectURLs.removeValue(forKey: task.taskIdentifier)
            self.activeTaskCount = max(self.activeTaskCount - 1, 0)

            if let track, DesktopPetMusicTrack.isPlayableExternalRedirectURL(redirectURL) {
                self.playableTracks.append(track)
            }

            if self.playableTracks.count >= self.targetCount {
                self.finish(with: Array(self.playableTracks.prefix(self.targetCount)))
                return
            }

            self.startMoreRequests()
        }
    }

    private func startMoreRequests() {
        guard !isCancelled, let session, completion != nil else { return }

        while activeTaskCount < maximumConcurrentRequests,
              nextIndex < candidates.count,
              playableTracks.count < targetCount {
            let track = candidates[nextIndex]
            nextIndex += 1

            var request = URLRequest(url: track.externalPlaybackURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

            let task = session.dataTask(with: request)
            taskTracks[task.taskIdentifier] = track
            activeTaskCount += 1
            task.resume()
        }

        if nextIndex >= candidates.count, activeTaskCount == 0 {
            finish(with: playableTracks)
        }
    }

    private func finish(with tracks: [DesktopPetMusicTrack]) {
        guard let completion else { return }
        self.completion = nil
        isCancelled = true
        taskTracks.removeAll()
        redirectURLs.removeAll()
        session?.invalidateAndCancel()
        session = nil

        DispatchQueue.main.async {
            completion(tracks)
        }
    }
}

private final class DesktopPetMusicURLResolver: NSObject, URLSessionTaskDelegate {
    private var session: URLSession?
    private var redirectURL: URL?
    private var completion: ((URL?) -> Void)?

    func resolve(_ url: URL, completion: @escaping (URL?) -> Void) {
        self.completion = completion
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            let resolvedURL = self.redirectURL ?? response?.url ?? url
            self.finish(with: DesktopPetMusicTrack.preferredHTTPSPlaybackURL(from: resolvedURL))
        }.resume()
    }

    func cancel() {
        completion = nil
        redirectURL = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectURL = request.url
        completionHandler(nil)
    }

    private func finish(with url: URL?) {
        let completion = completion
        self.completion = nil
        redirectURL = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion?(url)
    }
}
