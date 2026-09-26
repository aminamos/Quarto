import Foundation

struct LoginResponse: Decodable {
    let user: User
    let userDefaultLibraryId: String?
}

struct User: Decodable {
    let id: String
    let username: String
    let token: String?
    let accessToken: String?
    let refreshToken: String?
    let mediaProgress: [MediaProgress]

    var bearerToken: String { accessToken ?? token ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, username, token, accessToken, refreshToken, mediaProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        mediaProgress = try container.decodeIfPresent([MediaProgress].self, forKey: .mediaProgress) ?? []
    }
}

public struct SessionChapter: Codable, Hashable, Sendable {
    public let id: Int?
    public let start: Double
    public let end: Double
    public let title: String

    public init(id: Int? = nil, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

struct MediaProgress: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Double?

    init(id: String, libraryItemId: String, episodeId: String?, duration: Double?, progress: Double?, currentTime: Double?, isFinished: Bool?, lastUpdate: Double?) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.duration = duration
        self.progress = progress
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }

    var compositeKey: String {
        if let episodeId {
            return "\(libraryItemId)-\(episodeId)"
        }
        return libraryItemId
    }

    var remainingText: String {
        if isFinished == true { return "Finished" }
        return Format.remaining(currentTime: currentTime, duration: duration)
    }

    var progressFraction: Double {
        if let progress { return min(1, max(0, progress)) }
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, (currentTime ?? 0) / duration))
    }
}

struct LibrariesResponse: Decodable {
    let libraries: [Library]
}

struct Library: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let mediaType: String
    let displayOrder: Int?

    var isPodcast: Bool { mediaType == "podcast" }
}

struct LibraryItemsResponse: Decodable {
    let results: [LibraryItem]
    let total: Int?
}

struct PersonalizedSection: Decodable, Identifiable {
    let id: String
    let label: String?
    let type: String?
    let entities: [LibraryItem]
}

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: String
    let libraryId: String?
    let mediaType: String?
    let media: Media?
    let recentEpisode: PodcastEpisode?
    let addedAt: Double? = nil
    let updatedAt: Double? = nil

    var title: String { media?.metadata.title ?? "Untitled" }
    var author: String {
        media?.metadata.authorName
            ?? media?.metadata.author
            ?? media?.metadata.narratorName
            ?? ""
    }
    var duration: Double? { media?.duration ?? recentEpisode?.resolvedDuration }
}

struct Media: Codable, Hashable {
    let metadata: Metadata
    let duration: Double?
    let episodes: [PodcastEpisode]?
    let numEpisodes: Int?
    let tags: [String]?
    let chapters: [SessionChapter]?
}

struct Metadata: Codable, Hashable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let author: String?
    let narratorName: String?
    let seriesName: String?
    let description: String?
    let genres: [String]?
    let publishedYear: String?
    let releaseDate: String?
}

struct PodcastEpisode: Codable, Identifiable, Hashable {
    let id: String
    let libraryItemId: String?
    let title: String?
    let subtitle: String?
    let description: String?
    let season: String?
    let publishedAt: Double?
    let duration: Double?
    let audioFile: AudioFile?
    let podcast: PodcastEmbed?
    let chapters: [SessionChapter]?

    var showTitle: String? { podcast?.metadata.title }
    var resolvedDuration: Double? { duration ?? audioFile?.duration }
}

struct PodcastEmbed: Codable, Hashable {
    let metadata: Metadata
}

struct AudioFile: Codable, Hashable {
    let duration: Double?
    let mimeType: String?
}

struct RecentEpisodesResponse: Decodable {
    let episodes: [PodcastEpisode]
}

struct PlaybackSession: Decodable {
    let id: String
    let libraryItemId: String?
    let episodeId: String?
    let displayTitle: String?
    let displayAuthor: String?
    let duration: Double?
    let currentTime: Double?
    let audioTracks: [AudioTrack]
    let chapters: [SessionChapter]?
}

struct AudioTrack: Decodable {
    let contentUrl: String
    let duration: Double?
    let mimeType: String?
    let title: String?
}

struct SessionCredentials: Codable, Equatable {
    var serverURL: String
    var accessToken: String
    var refreshToken: String?
    var username: String
    var userId: String
    var defaultLibraryId: String?
    var password: String?

    enum CodingKeys: String, CodingKey {
        case serverURL, accessToken, refreshToken, username, userId, defaultLibraryId, password, token
    }

    init(serverURL: String, accessToken: String, refreshToken: String?, username: String, userId: String, defaultLibraryId: String?, password: String?) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.username = username
        self.userId = userId
        self.defaultLibraryId = defaultLibraryId
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
            ?? container.decodeIfPresent(String.self, forKey: .token)
            ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        username = try container.decode(String.self, forKey: .username)
        userId = try container.decode(String.self, forKey: .userId)
        defaultLibraryId = try container.decodeIfPresent(String.self, forKey: .defaultLibraryId)
        password = try container.decodeIfPresent(String.self, forKey: .password)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encode(username, forKey: .username)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(defaultLibraryId, forKey: .defaultLibraryId)
        try container.encodeIfPresent(password, forKey: .password)
    }
}

enum BrowseRoute: Hashable {
    case library
    case series
    case collections
    case playlists
    case authors
    case narrators
    case genres
    case bookmarks
    case downloaded
}

struct BrowseRow: Identifiable {
    let id: BrowseRoute
    let title: String
    let systemImage: String
}

enum BrowseCatalog {
    static let bookRows: [BrowseRow] = [
        .init(id: .library, title: "Library", systemImage: "books.vertical"),
        .init(id: .series, title: "Series", systemImage: "square.stack.3d.up"),
        .init(id: .collections, title: "Collections", systemImage: "rectangle.stack.badge.play"),
        .init(id: .playlists, title: "Playlists", systemImage: "list.bullet.rectangle"),
        .init(id: .authors, title: "Authors", systemImage: "person"),
        .init(id: .narrators, title: "Narrators", systemImage: "person.wave.2"),
        .init(id: .genres, title: "Genres", systemImage: "number"),
        .init(id: .bookmarks, title: "Bookmarks", systemImage: "bookmark"),
        .init(id: .downloaded, title: "Downloaded", systemImage: "arrow.down.circle")
    ]
}

struct DownloadedFile: Codable, Hashable, Identifiable {
    var id: String { key }
    var libraryItemId: String
    var episodeId: String?
    var title: String
    var author: String
    var relativePath: String
    var duration: Double?
    var downloadedAt: Double? = nil

    var key: String {
        if let episodeId { return "\(libraryItemId):\(episodeId)" }
        return libraryItemId
    }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case tiles
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiles: "Tiles"
        case .list: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .tiles: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title
    case author
    case lastListened
    case dateAdded
    case downloadDate
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .lastListened: "Last listened"
        case .dateAdded: "Date added"
        case .downloadDate: "Download date"
        case .duration: "Duration"
        }
    }
}

enum LibrarySorting {
    static func normalizedTimestamp(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return value > 1_000_000_000_000 ? value / 1_000 : value
    }

    static func sorted(
        _ items: [LibraryItem],
        by sort: LibrarySort,
        lastListened: (LibraryItem) -> Double?,
        downloadedAt: (LibraryItem) -> Double?
    ) -> [LibraryItem] {
        switch sort {
        case .title:
            return items.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .author:
            return items.sorted {
                let comparison = $0.author.localizedCaseInsensitiveCompare($1.author)
                if comparison == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
        case .lastListened:
            return items.sorted {
                dateDescending(
                    normalizedTimestamp(lastListened($0)),
                    normalizedTimestamp(lastListened($1)),
                    tie: $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                )
            }
        case .dateAdded:
            return items.sorted {
                dateDescending(
                    normalizedTimestamp($0.addedAt),
                    normalizedTimestamp($1.addedAt),
                    tie: $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                )
            }
        case .downloadDate:
            return items.sorted {
                dateDescending(
                    normalizedTimestamp(downloadedAt($0)),
                    normalizedTimestamp(downloadedAt($1)),
                    tie: $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                )
            }
        case .duration:
            return items.sorted {
                let left = $0.duration ?? -1
                let right = $1.duration ?? -1
                if left == right {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return left > right
            }
        }
    }

    private static func dateDescending(
        _ left: Double?,
        _ right: Double?,
        tie: Bool
    ) -> Bool {
        switch (left, right) {
        case let (l?, r?):
            if l == r { return tie }
            return l > r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return tie
        }
    }
}
