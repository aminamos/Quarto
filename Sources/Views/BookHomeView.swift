import SwiftUI

struct BookHomeView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(BrowseCatalog.bookRows) { row in
                    NavigationLink(value: row.id) {
                        HStack(spacing: 16) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: 18, weight: .regular))
                                .frame(width: 28)
                            Text(row.title)
                                .font(.title3)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(QuartoTheme.muted)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                    }
                }
                if !model.continueItems.isEmpty {
                    Text("Continue")
                        .font(.title.weight(.semibold))
                        .padding(.top, 28)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(model.continueItems) { item in
                                ContinueCard(item: item)
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
            .padding(.horizontal, 20)
        }
        .background(QuartoTheme.bg)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(model.selectedLibrary?.name ?? "Audiobooks")
                .font(QuartoTheme.titleFont)
                .lineLimit(1)
            Spacer()
            CircleIconButton(systemName: "magnifyingglass") {}
            Menu {
                Button("Settings") {
                    #if os(macOS)
                    openSettings()
                    #else
                    model.showSettings = true
                    #endif
                }
                Divider()
                ForEach(model.libraries) { library in
                    Button {
                        Task { await model.selectLibrary(library) }
                    } label: {
                        if library.id == model.selectedLibrary?.id {
                            Label(library.name, systemImage: "checkmark")
                        } else {
                            libraryLabel(library)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(QuartoTheme.chip))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func libraryLabel(_ library: Library) -> some View {
        Label {
            Text(library.name)
        } icon: {
            Image(systemName: library.isPodcast ? "antenna.radiowaves.left.and.right" : "headphones")
        }
    }
}

struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItem

    var body: some View {
        Button {
            Task { await model.play(item: item, episode: item.recentEpisode) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(url: model.coverURL(for: item.id), corner: 8)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(item.author)
                        .font(.subheadline)
                        .foregroundStyle(QuartoTheme.muted)
                        .lineLimit(1)
                    if let progress = model.progress(for: item.id, episodeId: item.recentEpisode?.id) {
                        Label(progress.remainingText, systemImage: "headphones")
                            .font(.caption)
                            .foregroundStyle(QuartoTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(QuartoTheme.card))
        }
        .buttonStyle(.plain)
    }
}

struct BrowseDestinationView: View {
    @Environment(AppModel.self) private var model
    let route: BrowseRoute
    @State private var deletingDownloadKey: String?

    var body: some View {
        Group {
            switch route {
            case .downloaded:
                if model.downloads.files.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloaded Audiobooks", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Audiobooks you download will appear here for offline listening.")
                    }
                } else {
                    List(model.downloads.files) { file in
                        HStack(spacing: 14) {
                            Button {
                                play(file: file)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: model.coverURL(for: file.libraryItemId), corner: 8)
                                        .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.title)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(file.author)
                                            .font(.caption)
                                            .foregroundStyle(QuartoTheme.muted)
                                            .lineLimit(1)
                                        if let duration = file.duration {
                                            Text(Format.duration(duration))
                                                .font(.caption2)
                                                .foregroundStyle(QuartoTheme.muted)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                guard deletingDownloadKey != file.key else { return }
                                deletingDownloadKey = file.key
                                Task { @MainActor in
                                    await Task.yield()
                                    withAnimation {
                                        model.downloads.remove(file)
                                    }
                                    deletingDownloadKey = nil
                                }
                            } label: {
                                if deletingDownloadKey == file.key {
                                    ProgressView()
                                        .tint(.red)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.body)
                                        .foregroundStyle(.red.opacity(0.8))
                                        .padding(8)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(deletingDownloadKey != nil)
                        }
                        .listRowBackground(QuartoTheme.bg)
                    }
                    .listStyle(.plain)
                }
            case .library:
                ItemGridView(items: model.libraryItems)
            default:
                ContentUnavailableView(title(route), systemImage: "hammer", description: Text("Not wired to the API yet."))
            }
        }
        .navigationTitle(title(route))
        .background(QuartoTheme.bg)
    }

    private func play(file: DownloadedFile) {
        if let episodeId = file.episodeId {
            let stub = PodcastEpisode(
                id: episodeId,
                libraryItemId: file.libraryItemId,
                title: file.title,
                subtitle: nil,
                description: nil,
                season: nil,
                publishedAt: nil,
                duration: file.duration,
                audioFile: nil,
                podcast: nil,
                chapters: nil
            )
            Task { await model.playEpisode(stub) }
        } else if let existing = model.libraryItems.first(where: { $0.id == file.libraryItemId }) {
            Task { await model.play(item: existing) }
        } else {
            let metadata = Metadata(
                title: file.title,
                subtitle: nil,
                authorName: file.author,
                author: file.author,
                narratorName: nil,
                seriesName: nil,
                description: nil,
                genres: nil,
                publishedYear: nil,
                releaseDate: nil
            )
            let media = Media(
                metadata: metadata,
                duration: file.duration,
                episodes: nil,
                numEpisodes: nil,
                tags: nil,
                chapters: nil
            )
            let stub = LibraryItem(
                id: file.libraryItemId,
                libraryId: model.selectedLibrary?.id,
                mediaType: "book",
                media: media,
                recentEpisode: nil
            )
            Task { await model.play(item: stub) }
        }
    }

    private func title(_ route: BrowseRoute) -> String {
        BrowseCatalog.bookRows.first { $0.id == route }?.title ?? "Browse"
    }
}

struct ItemGridView: View {
    @Environment(AppModel.self) private var model
    let items: [LibraryItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 8) {
                            CoverImage(url: model.coverURL(for: item.id), corner: 8)
                                .aspectRatio(1, contentMode: .fit)
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding()
        }
        .background(QuartoTheme.bg)
    }
}
