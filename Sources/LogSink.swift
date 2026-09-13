import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public actor LogSink {
    public static let shared = LogSink()

    public struct LogEntry: Codable, Sendable, Equatable {
        public let ts: String
        public let level: String
        public let tag: String
        public let message: String
        public let meta: [String: String]?

        public init(ts: String, level: String, tag: String, message: String, meta: [String: String]?) {
            self.ts = ts
            self.level = level
            self.tag = tag
            self.message = message
            self.meta = meta
        }
    }

    private var url: String = ""
    private var token: String = ""
    private var appName: String = "Quarto"
    private var buildNumber: String = "1"
    private var deviceIdValue: String = "unknown"

    private var queue: [LogEntry] = []
    private var timerTask: Task<Void, Never>?

    private static let sensitiveKeys: Set<String> = [
        "token", "password", "secret", "authorization", "cookie",
        "apikey", "api_key", "refreshtoken", "refresh_token",
        "accessjwt", "access_jwt", "bearer"
    ]

    private init() {
        Task {
            await startTimer()
        }
    }

    public func configure(url: String, token: String, app: String = "Quarto", build: String = "1", deviceId: String = "unknown") {
        self.url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
        self.appName = app
        self.buildNumber = build
        self.deviceIdValue = deviceId
    }

    public func configureFromDefaults() async {
        let defaults = UserDefaults.standard
        let savedURL = defaults.string(forKey: "quarto_log_sink_url") ?? ""
        let savedToken = defaults.string(forKey: "quarto_log_sink_token") ?? ""
        let enabled = defaults.bool(forKey: "quarto_use_log_sink")
        
        #if os(iOS)
        let deviceId = await MainActor.run {
            UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
        }
        #else
        let deviceId = Host.current().localizedName ?? "macos-device"
        #endif
        
        let app = "Quarto"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        if enabled && !savedURL.isEmpty {
            configure(url: savedURL, token: savedToken, app: app, build: build, deviceId: deviceId)
        } else {
            configure(url: "", token: "", app: app, build: build, deviceId: deviceId)
        }
    }

    public func log(level: String, tag: String, message: String, meta: [String: Sendable]? = nil) {
        guard !url.isEmpty else { return }
        
        let cleanedLevel = ["debug", "info", "warn", "error"].contains(level.lowercased()) ? level.lowercased() : "info"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())

        let sanitizedMeta = meta.map { Self.redactedMeta($0) }
        let sanitizedMessage = Self.redactedMessage(message)

        let entry = LogEntry(
            ts: ts,
            level: cleanedLevel,
            tag: tag,
            message: sanitizedMessage,
            meta: sanitizedMeta
        )

        queue.append(entry)
        if queue.count > 500 {
            queue.removeFirst(queue.count - 500)
        }

        if queue.count >= 50 {
            Task {
                await flush()
            }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                await flush()
            }
        }
    }

    public func flush() async {
        guard !url.isEmpty, !queue.isEmpty else { return }
        let batch = Array(queue.prefix(50))
        queue.removeFirst(batch.count)

        struct Payload: Codable, Sendable {
            let app: String
            let build: String?
            let deviceId: String?
            let entries: [LogEntry]
        }

        let payload = Payload(
            app: appName,
            build: buildNumber.isEmpty ? nil : buildNumber,
            deviceId: deviceIdValue.isEmpty ? nil : deviceIdValue,
            entries: batch
        )

        guard let endpointURL = URL(string: "\(url)/v1/logs") else { return }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // Silent failure per contract
            }
        } catch {
            // Silent failure
        }
    }

    public static func redactedMeta(_ meta: [String: Sendable]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, val) in meta {
            let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if sensitiveKeys.contains(normalizedKey) || sensitiveKeys.contains(key.lowercased()) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = String(describing: val)
            }
        }
        return result
    }

    public static func redactedMeta(_ meta: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, val) in meta {
            let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if sensitiveKeys.contains(normalizedKey) || sensitiveKeys.contains(key.lowercased()) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = String(describing: val)
            }
        }
        return result
    }

    public static func redactedMessage(_ message: String) -> String {
        var mutableMessage = message
        let pattern = #"(?i)\b(token|password|secret|authorization|cookie|apikey|api_key|refreshtoken|refresh_token|accessjwt|access_jwt|bearer)\b\s*([=:])\s*([^\s,;]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(mutableMessage.startIndex..<mutableMessage.endIndex, in: mutableMessage)
            let matches = regex.matches(in: mutableMessage, options: [], range: range)
            for match in matches.reversed() {
                if match.numberOfRanges >= 4,
                   let keyRange = Range(match.range(at: 1), in: mutableMessage),
                   let sepRange = Range(match.range(at: 2), in: mutableMessage),
                   let valueRange = Range(match.range(at: 3), in: mutableMessage) {
                    let keyStr = mutableMessage[keyRange]
                    let sepStr = mutableMessage[sepRange]
                    var valueStr = String(mutableMessage[valueRange])
                    var trailing = ""
                    while let last = valueStr.last, ".!?:;)]}'\"".contains(last) {
                        trailing.insert(last, at: trailing.startIndex)
                        valueStr.removeLast()
                    }
                    let replacement = "\(keyStr)\(sepStr)[REDACTED]\(trailing)"
                    if let fullRange = Range(match.range(at: 0), in: mutableMessage) {
                        mutableMessage.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }
        return mutableMessage
    }
}
