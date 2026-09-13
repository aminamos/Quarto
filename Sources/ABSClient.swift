import Foundation

@MainActor
final class ABSClient {
    let baseURL: URL
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    var username: String?
    var password: String?
    var onTokensUpdated: ((String, String?) -> Void)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private var refreshTask: Task<Void, Error>?

    init(baseURL: URL, accessToken: String? = nil, refreshToken: String? = nil, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.username = username
        self.password = password
    }

    var token: String? { accessToken }

    func login(username: String, password: String) async throws -> LoginResponse {
        self.username = username
        self.password = password
        let response: LoginResponse = try await post(
            "/login",
            body: ["username": username, "password": password],
            authed: false,
            extraHeaders: ["x-return-tokens": "true"]
        )
        applyLogin(response)
        return response
    }

    func libraries() async throws -> [Library] {
        let response: LibrariesResponse = try await get("/api/libraries")
        return response.libraries.sorted { ($0.displayOrder ?? 0) < ($1.displayOrder ?? 0) }
    }

    func items(libraryId: String, limit: Int = 50, page: Int = 0, minified: Bool = true) async throws -> [LibraryItem] {
        let response: LibraryItemsResponse = try await get(
            "/api/libraries/\(libraryId)/items",
            query: [
                "limit": String(limit),
                "page": String(page),
                "minified": minified ? "1" : "0",
                "sort": "media.metadata.title"
            ]
        )
        return response.results
    }

    func personalized(libraryId: String) async throws -> [PersonalizedSection] {
        try await get("/api/libraries/\(libraryId)/personalized")
    }

    func recentEpisodes(libraryId: String, limit: Int = 40) async throws -> [PodcastEpisode] {
        let response: RecentEpisodesResponse = try await get(
            "/api/libraries/\(libraryId)/recent-episodes",
            query: ["limit": String(limit)]
        )
        return response.episodes
    }

    func item(id: String) async throws -> LibraryItem {
        try await get("/api/items/\(id)", query: ["expanded": "1"])
    }
    func me() async throws -> User {
        try await get("/api/me")
    }

    func play(itemId: String, episodeId: String?) async throws -> PlaybackSession {
        let path = if let episodeId {
            "/api/items/\(itemId)/play/\(episodeId)"
        } else {
            "/api/items/\(itemId)/play"
        }
        let body: [String: Any] = [
            "deviceInfo": [
                "clientName": "Quarto",
                "clientVersion": "0.1.0",
                "manufacturer": "Apple",
                "model": "iPhone"
            ],
            "supportedMimeTypes": ["audio/mpeg", "audio/mp4", "audio/m4b", "audio/flac", "audio/aac", "audio/ogg"]
        ]
        return try await post(path, body: body)
    }

    func syncSession(id: String, currentTime: Double, duration: Double, timeListened: Double) async throws {
        try await postEmpty(
            "/api/session/\(id)/sync",
            body: [
                "currentTime": currentTime,
                "duration": duration,
                "timeListened": timeListened
            ]
        )
    }

    func closeSession(id: String, currentTime: Double, duration: Double, timeListened: Double) async throws {
        try await postEmpty(
            "/api/session/\(id)/close",
            body: [
                "currentTime": currentTime,
                "duration": duration,
                "timeListened": timeListened
            ]
        )
    }

    func checkNewEpisodes(itemId: String) async throws {
        try await postEmpty("/api/podcasts/\(itemId)/checknew", body: [:])
    }

    func coverURL(itemId: String) -> URL? {
        guard let targetURL = try? endpoint("/api/items/\(itemId)/cover"),
              var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = [URLQueryItem(name: "width", value: "400")]
        if let accessToken {
            items.append(URLQueryItem(name: "token", value: accessToken))
        }
        components.queryItems = items
        return components.url
    }

    func absoluteURL(_ path: String, authed: Bool = true) -> URL? {
        let resolved: URL? = if let url = URL(string: path), url.scheme != nil {
            url
        } else {
            URL(string: path, relativeTo: baseURL)?.absoluteURL
        }
        guard let resolved else { return nil }
        if authed, let token = accessToken, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "token" }) {
                items.append(URLQueryItem(name: "token", value: token))
                components.queryItems = items
                return components.url ?? resolved
            }
        }
        return resolved
    }

    func authorizedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        applyAuth(&request)
        return request
    }

    func ensureFreshAccessToken() async throws {
        if let accessToken, !JWT.needsRefresh(accessToken) { return }
        try await refreshSession()
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await ensureFreshAccessToken()
        let targetURL = try endpoint(path)
        guard var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            throw ABSError.badURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw ABSError.badURL
        }
        var request = URLRequest(url: url)
        applyAuth(&request)
        return try await decode(request)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authed: Bool = true, extraHeaders: [String: String] = [:]) async throws -> T {
        if authed { try await ensureFreshAccessToken() }
        let targetURL = try endpoint(path)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if authed { applyAuth(&request) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(request)
    }

    private func postEmpty(_ path: String, body: [String: Any]) async throws {
        try await ensureFreshAccessToken()
        let targetURL = try endpoint(path)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ABSError.badResponse
        }
        if http.statusCode == 401 && shouldRefresh(after: request) {
            try await refreshSession()
            var retry = request
            applyAuth(&retry)
            let (retryData, retryResponse) = try await session.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse, (200..<300).contains(retryHttp.statusCode) else {
                let code = (retryResponse as? HTTPURLResponse)?.statusCode ?? 500
                let msg = String(data: retryData, encoding: .utf8) ?? ""
                throw ABSError.http(code, msg)
            }
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ABSError.http(http.statusCode, message)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: root + suffix) else {
            throw ABSError.badURL
        }
        return url
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func decode<T: Decodable>(_ request: URLRequest, retried: Bool = false) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ABSError.badResponse
        }
        if http.statusCode == 401, !retried, shouldRefresh(after: request) {
            try await refreshSession()
            var retry = request
            applyAuth(&retry)
            return try await decode(retry, retried: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ABSError.http(http.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func shouldRefresh(after request: URLRequest) -> Bool {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/login") || path.hasSuffix("/auth/refresh") { return false }
        return true
    }

    private func refreshSession() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let task = Task { @MainActor in
            try await self.rotateOrRelogin()
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func rotateOrRelogin() async throws {
        if let refreshToken {
            do {
                try await performRefresh(refreshToken)
                return
            } catch {
                // Session row gone or token rotated out from under us; fall back to password.
            }
        }
        guard let username, let password, !password.isEmpty else {
            throw ABSError.http(401, "Session expired")
        }
        _ = try await login(username: username, password: password)
    }

    private func performRefresh(_ refreshToken: String) async throws {
        let targetURL = try endpoint("/auth/refresh")
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ABSError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ABSError.http(http.statusCode, message)
        }
        let login = try JSONDecoder().decode(LoginResponse.self, from: data)
        applyLogin(login)
    }

    private func applyLogin(_ response: LoginResponse) {
        accessToken = response.user.bearerToken
        if let next = response.user.refreshToken, !next.isEmpty {
            refreshToken = next
        }
        username = response.user.username
        if let accessToken {
            onTokensUpdated?(accessToken, refreshToken)
        }
    }
}

enum ABSError: LocalizedError {
    case badURL
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid server URL"
        case .badResponse:
            return "Invalid response"
        case .http(let code, let body):
            if code == 401 {
                if body.localizedCaseInsensitiveContains("session") {
                    return "Session expired"
                }
                return "Not authorized"
            }
            return "Server error \(code)\(body.isEmpty ? "" : ": \(body.prefix(180))")"
        }
    }
}
