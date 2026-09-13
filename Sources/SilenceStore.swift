import Foundation
import Observation

@MainActor
@Observable
final class SilenceStore {
    private let fileURL: URL
    private(set) var store: [String: [SilenceSegment]] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quarto", isDirectory: true)
        fileURL = base.appendingPathComponent("silence_segments.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func segments(for key: String) -> [SilenceSegment] {
        store[key] ?? []
    }

    func hasSegments(for key: String) -> Bool {
        !(store[key] ?? []).isEmpty
    }

    func save(_ segments: [SilenceSegment], for key: String) {
        if segments.isEmpty {
            store.removeValue(forKey: key)
        } else {
            store[key] = segments
        }
        persist()
    }

    func remove(for key: String) {
        store.removeValue(forKey: key)
        persist()
    }

    func clear() {
        store.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        store = (try? JSONDecoder().decode([String: [SilenceSegment]].self, from: data)) ?? [:]
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
