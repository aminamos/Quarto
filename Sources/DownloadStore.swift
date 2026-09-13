import Foundation

@MainActor
final class DownloadStore {
    private let folder: URL
    private let indexURL: URL
    private(set) var files: [DownloadedFile] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quarto/downloads", isDirectory: true)
        folder = base
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func file(itemId: String, episodeId: String?) -> DownloadedFile? {
        let key = DownloadedFile(libraryItemId: itemId, episodeId: episodeId, title: "", author: "", relativePath: "", duration: nil).key
        return files.first { $0.key == key }
    }

    func localURL(for file: DownloadedFile) -> URL {
        folder.appendingPathComponent(file.relativePath)
    }

    func isDownloaded(itemId: String, episodeId: String?) -> Bool {
        file(itemId: itemId, episodeId: episodeId) != nil
    }

    func remove(itemId: String, episodeId: String?) {
        if let found = file(itemId: itemId, episodeId: episodeId) {
            remove(found)
        }
    }

    func clearAll() {
        for file in files {
            try? FileManager.default.removeItem(at: localURL(for: file))
        }
        files.removeAll()
        persist()
    }

    var totalSizeBytes: Int64 {
        files.reduce(0) { total, file in
            let path = localURL(for: file).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    func cleanTemporaryAdScans() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in contents {
                let name = file.lastPathComponent
                if name.hasPrefix("adscan_") || name.hasPrefix("batch_adscan_") || name.hasPrefix("silencescan_") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func save(itemId: String, episodeId: String?, title: String, author: String, duration: Double?, tempURL: URL, ext: String) throws -> DownloadedFile {
        let name = "\(itemId)_\(episodeId ?? "item").\(ext)"
        let dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        let record = DownloadedFile(
            libraryItemId: itemId,
            episodeId: episodeId,
            title: title,
            author: author,
            relativePath: name,
            duration: duration
        )
        files.removeAll { $0.key == record.key }
        files.insert(record, at: 0)
        persist()
        return record
    }

    func remove(_ file: DownloadedFile) {
        try? FileManager.default.removeItem(at: localURL(for: file))
        files.removeAll { $0.key == file.key }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        files = (try? JSONDecoder().decode([DownloadedFile].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(files) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
