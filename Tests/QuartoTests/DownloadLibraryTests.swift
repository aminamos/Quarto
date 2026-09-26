import Foundation
import Testing
@testable import Quarto

private func makeLibraryItem(
    id: String,
    title: String,
    author: String = "",
    duration: Double? = nil,
    addedAt: Double? = nil
) -> LibraryItem {
    let metadata = Metadata(
        title: title,
        subtitle: nil,
        authorName: author,
        author: author,
        narratorName: nil,
        seriesName: nil,
        description: nil,
        genres: nil,
        publishedYear: nil,
        releaseDate: nil
    )
    let media = Media(
        metadata: metadata,
        duration: duration,
        episodes: nil,
        numEpisodes: nil,
        tags: nil,
        chapters: nil
    )
    return LibraryItem(
        id: id,
        libraryId: nil,
        mediaType: "book",
        media: media,
        recentEpisode: nil,
        addedAt: addedAt,
        updatedAt: nil
    )
}

struct DownloadProgressTests {
    @Test func fractionNeedsPositiveExpectedBytes() {
        #expect(DownloadProgressDelegate.fraction(written: 10, expected: 0) == nil)
        #expect(DownloadProgressDelegate.fraction(written: 10, expected: -5) == nil)
        #expect(DownloadProgressDelegate.fraction(written: -1, expected: 100) == nil)
    }

    @Test func fractionIsClamped() {
        #expect(DownloadProgressDelegate.fraction(written: 0, expected: 100) == 0)
        #expect(DownloadProgressDelegate.fraction(written: 50, expected: 100) == 0.5)
        #expect(DownloadProgressDelegate.fraction(written: 200, expected: 100) == 1)
    }

    @Test func downloadKeysMatchStoredKeys() {
        #expect(AppModel.downloadKey(itemId: "book1", episodeId: nil) == "book1")
        #expect(AppModel.downloadKey(itemId: "show1", episodeId: "ep1") == "show1:ep1")
    }
}

struct LibrarySortingTests {
    @Test func normalizedTimestampsAcceptMillisAndSeconds() {
        #expect(LibrarySorting.normalizedTimestamp(nil) == nil)
        #expect(LibrarySorting.normalizedTimestamp(1_700_000_000) == 1_700_000_000)
        #expect(LibrarySorting.normalizedTimestamp(1_700_000_000_000) == 1_700_000_000)
    }

    @Test func sortsByTitleThenAuthor() {
        let items = [
            makeLibraryItem(id: "b", title: "beta", author: "Zed"),
            makeLibraryItem(id: "a", title: "Alpha", author: "Amy"),
            makeLibraryItem(id: "c", title: "alpha", author: "Zed"),
        ]
        let byTitle = LibrarySorting.sorted(
            items,
            by: .title,
            lastListened: { _ in nil },
            downloadedAt: { _ in nil }
        )
        #expect(byTitle.map(\.id) == ["a", "c", "b"])

        let byAuthor = LibrarySorting.sorted(
            items,
            by: .author,
            lastListened: { _ in nil },
            downloadedAt: { _ in nil }
        )
        #expect(byAuthor.map(\.id) == ["a", "c", "b"])
    }

    @Test func dateSortsPutMissingValuesLast() {
        let items = [
            makeLibraryItem(id: "old", title: "Old", addedAt: 10),
            makeLibraryItem(id: "missing", title: "Missing"),
            makeLibraryItem(id: "new", title: "New", addedAt: 30),
        ]
        let sorted = LibrarySorting.sorted(
            items,
            by: .dateAdded,
            lastListened: { _ in nil },
            downloadedAt: { _ in nil }
        )
        #expect(sorted.map(\.id) == ["new", "old", "missing"])
    }

    @Test func downloadDateSortUsesProvidedTimestamps() {
        let items = [
            makeLibraryItem(id: "a", title: "A"),
            makeLibraryItem(id: "b", title: "B"),
        ]
        let sorted = LibrarySorting.sorted(
            items,
            by: .downloadDate,
            lastListened: { _ in nil },
            downloadedAt: { $0.id == "b" ? 20 : 10 }
        )
        #expect(sorted.map(\.id) == ["b", "a"])
    }
}
