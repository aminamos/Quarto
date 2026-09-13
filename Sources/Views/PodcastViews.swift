import SwiftUI

struct PodcastHomeView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var tab = PodcastTab.latest
    @State private var isSelecting = false
    @State private var selectedEpisodeIds: Set<String> = []
    @State private var deletingDownloadKey: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if model.adStore.isScanning {
                        scanningBanner
                    }
                    if model.pendingDownloadCount > 0 {
                        downloadBanner
                    }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.libraryItems) { item in
                            NavigationLink(value: item) {
                                CoverImage(url: model.coverURL(for: item.id), corner: 10)
                                    .frame(width: 72, height: 72)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(PodcastTab.allCases, id: \.self) { item in
                        Button {
                            tab = item
                        } label: {
                            Text(item.title)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(tab == item ? Color.white : QuartoTheme.chip))
                                .foregroundStyle(tab == item ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                    episodeList
                        .padding(.bottom, isSelecting ? 120 : 80)
                }
                .padding(.horizontal, 20)
            }
            if isSelecting && tab != .shows {
                selectionActionBar
            }
        }
        .background(QuartoTheme.bg)
        .onChange(of: tab) { _, newTab in
            if newTab == .shows {
                isSelecting = false
                selectedEpisodeIds.removeAll()
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var header: some View {
        HStack {
            Text(model.selectedLibrary?.name ?? "Podcasts")
                .font(QuartoTheme.titleFont)
            Spacer()
            if tab != .shows {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedEpisodeIds.removeAll()
                        }
                    }
                } label: {
                    Text(isSelecting ? "Done" : "Select")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isSelecting ? Color.orange : QuartoTheme.chip))
                }
                .buttonStyle(.plain)
            }
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
                            Text(library.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(QuartoTheme.chip))
            }
        }
        .padding(.top, 8)
    }

    private var scanningBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Detecting Ads (\(model.adStore.completedCount + 1)/\(model.adStore.totalToScan))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text(model.adStore.currentScanTitle)
                    .font(.caption2)
                    .foregroundStyle(QuartoTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel") {
                model.adStore.cancelScan()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.15)))
    }

    private var downloadBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading Episodes")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text(model.pendingDownloadCount == 1 ? "1 episode left" : "\(model.pendingDownloadCount) episodes left")
                    .font(.caption2)
                    .foregroundStyle(QuartoTheme.muted)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.15)))
    }

    private var currentTabEpisodes: [PodcastEpisode] {
        switch tab {
        case .latest: return model.recentEpisodes
        case .shows: return []
        case .continueListening: return continueEpisodes
        case .downloaded: return downloadedEpisodes
        }
    }

    private var downloadedEpisodes: [PodcastEpisode] {
        model.downloads.files.compactMap { file -> PodcastEpisode? in
            guard let episodeId = file.episodeId else { return nil }
            if let existing = model.recentEpisodes.first(where: { $0.id == episodeId }) {
                return existing
            }
            return PodcastEpisode(
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
        }
    }

    private var allSelected: Bool {
        let current = currentTabEpisodes
        return !current.isEmpty && current.allSatisfy { selectedEpisodeIds.contains($0.id) }
    }

    private var selectionActionBar: some View {
        let targets = currentTabEpisodes.filter { selectedEpisodeIds.contains($0.id) }
        let downloadable = model.undownloadedCount(targets)
        return HStack(spacing: 14) {
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected {
                    selectedEpisodeIds.removeAll()
                } else {
                    selectedEpisodeIds = Set(currentTabEpisodes.map(\.id))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .fixedSize()

            Spacer()

            Button {
                Task { await model.downloadEpisodes(targets) }
                withAnimation {
                    isSelecting = false
                    selectedEpisodeIds.removeAll()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("Download (\(downloadable))")
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(downloadable == 0 ? Color.gray : Color.blue))
                .foregroundStyle(.white)
            }
            .disabled(downloadable == 0)

            Button {
                model.adStore.scanEpisodes(
                    targets,
                    client: model.client,
                    downloads: model.downloads,
                    adEngine: model.player.adEngine
                )
                withAnimation {
                    isSelecting = false
                    selectedEpisodeIds.removeAll()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shield.badge.checkmark")
                    Text("Ads (\(selectedEpisodeIds.count))")
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(selectedEpisodeIds.isEmpty ? Color.gray : Color.orange))
                .foregroundStyle(.white)
            }
            .disabled(selectedEpisodeIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color(white: 0.18)).shadow(radius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var episodeList: some View {
        switch tab {
        case .latest:
            ForEach(model.recentEpisodes) { episode in
                if isSelecting {
                    Button {
                        toggleSelect(episode.id)
                    } label: {
                        EpisodeRow(episode: episode, isSelecting: true, isSelected: selectedEpisodeIds.contains(episode.id))
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: episode) {
                        EpisodeRow(episode: episode)
                    }
                }
            }
        case .shows:
            ShowsListView()
        case .continueListening:
            ForEach(continueEpisodes) { episode in
                if isSelecting {
                    Button {
                        toggleSelect(episode.id)
                    } label: {
                        EpisodeRow(episode: episode, isSelecting: true, isSelected: selectedEpisodeIds.contains(episode.id))
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: episode) {
                        EpisodeRow(episode: episode)
                    }
                }
            }
        case .downloaded:
            let episodes = downloadedEpisodes
            if episodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(QuartoTheme.muted)
                    Text("No Downloaded Episodes")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Tap the download icon on any episode to listen offline.")
                        .font(.footnote)
                        .foregroundStyle(QuartoTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else if isSelecting {
                ForEach(episodes) { episode in
                    Button {
                        toggleSelect(episode.id)
                    } label: {
                        EpisodeRow(episode: episode, isSelecting: true, isSelected: selectedEpisodeIds.contains(episode.id))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(model.downloads.files.filter { $0.episodeId != nil }) { file in
                    HStack(spacing: 14) {
                        Button {
                            if let episodeId = file.episodeId {
                                let itemId = file.libraryItemId
                                let stub = PodcastEpisode(id: episodeId, libraryItemId: itemId, title: file.title, subtitle: nil, description: nil, season: nil, publishedAt: nil, duration: file.duration, audioFile: nil, podcast: nil, chapters: nil)
                                Task { await model.playEpisode(stub) }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                CoverImage(url: model.coverURL(for: file.libraryItemId), corner: 8)
                                    .frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.title)
                                        .foregroundStyle(.white)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(file.author)
                                        .foregroundStyle(QuartoTheme.muted)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(Format.duration(file.duration))
                                        .font(.caption)
                                        .foregroundStyle(QuartoTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.title2)
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
                    .padding(.vertical, 8)
                    Divider().overlay(QuartoTheme.hairline)
                }
            }
        }
    }
    private func toggleSelect(_ id: String) {
        if selectedEpisodeIds.contains(id) {
            selectedEpisodeIds.remove(id)
        } else {
            selectedEpisodeIds.insert(id)
        }
    }

    private var continueEpisodes: [PodcastEpisode] {
        model.recentEpisodes.filter { episode in
            guard let itemId = episode.libraryItemId else { return false }
            let progress = model.progress(for: itemId, episodeId: episode.id)
            return progress != nil && progress?.isFinished != true
        }
    }
}

enum PodcastTab: CaseIterable {
    case latest, shows, continueListening, downloaded
    var title: String {
        switch self {
        case .latest: "Latest"
        case .shows: "Shows"
        case .continueListening: "Continue"
        case .downloaded: "Downloaded"
        }
    }
}

struct PodcastShowEntry: Identifiable {
    let item: LibraryItem
    var id: String { item.id }
    var episodeCount: Int {
        item.media?.numEpisodes ?? item.media?.episodes?.count ?? 0
    }
}

enum PodcastShows {
    static func entries(from items: [LibraryItem]) -> [PodcastShowEntry] {
        items.map { PodcastShowEntry(item: $0) }.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
}
}
struct ShowsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = PodcastShows.entries(from: model.libraryItems)
        if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "square.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(QuartoTheme.muted)
                Text("No shows in this library yet.")
                    .font(.subheadline)
                    .foregroundStyle(QuartoTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            ForEach(entries) { entry in
                NavigationLink(value: entry.item) {
                    ShowRow(entry: entry)
                }
            }
        }
    }
}

struct ShowRow: View {
    @Environment(AppModel.self) private var model
    let entry: PodcastShowEntry

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(url: model.coverURL(for: entry.item.id), corner: 10)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !entry.item.author.isEmpty {
                    Text(entry.item.author)
                        .font(.caption)
                        .foregroundStyle(QuartoTheme.muted)
                        .lineLimit(1)
                }
                Text(entry.episodeCount == 1 ? "1 episode" : "\(entry.episodeCount) episodes")
                    .font(.caption2)
                    .foregroundStyle(QuartoTheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(QuartoTheme.muted)
        }
        .padding(.vertical, 8)
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode
    var isSelecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.orange : Color.white.opacity(0.6))
                    .padding(.top, 18)
            }
            CoverImage(url: episode.libraryItemId.flatMap(model.coverURL(for:)), corner: 8)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.relative(ms: episode.publishedAt))
                    .font(.caption)
                    .foregroundStyle(QuartoTheme.muted)
                Text(episode.title ?? "Episode")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                remaining
            }
            Spacer(minLength: 0)
            EpisodeDownloadStatus(episode: episode)
                .padding(.top, 18)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var remaining: some View {
        let itemId = episode.libraryItemId
        let progress = itemId.flatMap { model.progress(for: $0, episodeId: episode.id) }
        let text = progress?.remainingText.isEmpty == false ? progress!.remainingText : Format.duration(episode.resolvedDuration)
        HStack(spacing: 6) {
            if progress != nil {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
            }
            Text(text)
                .font(.subheadline)
        }
        .foregroundStyle(QuartoTheme.muted)
        if model.adStore.hasAds(for: episode.id, title: episode.title) {
            Label("\(model.adStore.segments(for: episode.id, title: episode.title).count) ads", systemImage: "shield.fill")
                .font(.caption)
                .foregroundStyle(Color.orange)
        }
    }
}

struct EpisodeDownloadStatus: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode

    var body: some View {
        if let itemId = episode.libraryItemId {
            let key = "\(itemId):\(episode.id)"
            if model.downloadingKey == key {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if model.downloads.isDownloaded(itemId: itemId, episodeId: episode.id) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let itemId: String
    @State private var item: LibraryItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSelecting = false
    @State private var selectedEpisodeIds: Set<String> = []
    var body: some View {
        ScrollView {
            if let item {
                VStack(spacing: 18) {
                    CoverImage(url: model.coverURL(for: item.id), corner: 16)
                        .frame(width: 220, height: 220)
                    Text(item.title)
                        .font(QuartoTheme.displayFont)
                        .multilineTextAlignment(.center)
                    Text(item.author)
                        .foregroundStyle(QuartoTheme.muted)
                    if let genre = item.media?.metadata.genres?.first {
                        Text(genre)
                            .font(.caption)
                            .foregroundStyle(QuartoTheme.muted)
                    }
                    WhitePlayPill(
                        title: (model.player.itemId == item.id) ? (model.player.isPlaying ? "Pause" : "Resume") : (item.mediaType == "podcast" ? "Latest Episode" : "Play"),
                        icon: (model.player.itemId == item.id && model.player.isPlaying) ? "pause.fill" : "play.fill"
                    ) {
                        Task {
                            if model.player.itemId == item.id {
                                model.player.toggle()
                            } else if item.mediaType == "podcast" {
                                if let latest = item.media?.episodes?.sorted(by: { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }).first {
                                    await model.play(item: item, episode: latest)
                                }
                            } else {
                                await model.play(item: item)
                            }
                        }
                    }
                    if let episodes = item.media?.episodes, !episodes.isEmpty {
                        HStack {
                            Text("Episodes")
                                .font(.title2.bold())
                            Spacer()
                            Text("See All (\(episodes.count))")
                                .foregroundStyle(QuartoTheme.muted)
                        }
                        .padding(.top, 12)
                        ForEach(episodes.sorted(by: { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) })) { episode in
                            if isSelecting {
                                Button {
                                    if selectedEpisodeIds.contains(episode.id) {
                                        selectedEpisodeIds.remove(episode.id)
                                    } else {
                                        selectedEpisodeIds.insert(episode.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedEpisodeIds.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selectedEpisodeIds.contains(episode.id) ? Color.orange : Color.white.opacity(0.6))
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(episode.title ?? "Episode")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                                .multilineTextAlignment(.leading)
                                            Text(Format.duration(episode.resolvedDuration))
                                                .font(.caption)
                                                .foregroundStyle(QuartoTheme.muted)
                                        }
                                        Spacer()
                                        EpisodeDownloadStatus(episode: episode)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                Divider().overlay(QuartoTheme.hairline)
                            } else {
                                NavigationLink(value: episode) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let season = episode.season, !season.isEmpty {
                                            Text("Season \(season)")
                                                .font(.caption)
                                                .foregroundStyle(QuartoTheme.muted)
                                        }
                                        HStack(alignment: .top) {
                                            Text(episode.title ?? "Episode")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 8)
                                            EpisodeDownloadStatus(episode: episode)
                                        }
                                        Text(Format.stripHTML(episode.subtitle ?? episode.description))
                                            .font(.subheadline)
                                            .foregroundStyle(QuartoTheme.muted)
                                            .lineLimit(2)
                                        Text(Format.duration(episode.resolvedDuration))
                                            .font(.caption)
                                            .foregroundStyle(QuartoTheme.muted)
                                        Divider().overlay(QuartoTheme.hairline)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            } else if isLoading {
                ProgressView().tint(.white).padding(.top, 80)
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Failed to Load")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(QuartoTheme.muted)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadItem() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                ContentUnavailableView("Item Not Found", systemImage: "questionmark.folder")
                    .padding(.top, 60)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelecting, let episodes = item?.media?.episodes, !episodes.isEmpty {
                let targets = episodes.filter { selectedEpisodeIds.contains($0.id) }
                let downloadable = model.undownloadedCount(targets)
                HStack(spacing: 14) {
                    Button(selectedEpisodeIds.count == episodes.count ? "Deselect All" : "Select All") {
                        if selectedEpisodeIds.count == episodes.count {
                            selectedEpisodeIds.removeAll()
                        } else {
                            selectedEpisodeIds = Set(episodes.map(\.id))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    Spacer()
                    Button {
                        Task { await model.downloadEpisodes(targets) }
                        withAnimation {
                            isSelecting = false
                            selectedEpisodeIds.removeAll()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download (\(downloadable))")
                        }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(downloadable == 0 ? Color.gray : Color.blue))
                        .foregroundStyle(.white)
                    }
                    .disabled(downloadable == 0)
                    Button {
                        model.adStore.scanEpisodes(
                            targets,
                            client: model.client,
                            downloads: model.downloads,
                            adEngine: model.player.adEngine
                        )
                        withAnimation {
                            isSelecting = false
                            selectedEpisodeIds.removeAll()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.badge.checkmark")
                            Text("Ads (\(selectedEpisodeIds.count))")
                        }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(selectedEpisodeIds.isEmpty ? Color.gray : Color.orange))
                        .foregroundStyle(.white)
                    }
                    .disabled(selectedEpisodeIds.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(QuartoTheme.card.shadow(radius: 8))
                .padding(.bottom, 16)
            }
        }
        .background(QuartoTheme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if let episodes = item?.media?.episodes, !episodes.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            withAnimation {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedEpisodeIds.removeAll()
                                }
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    Menu {
                        Button("Detect Ads in All Episodes") {
                            if let eps = item?.media?.episodes, !eps.isEmpty {
                                model.adStore.scanEpisodes(
                                    eps,
                                    client: model.client,
                                    downloads: model.downloads,
                                    adEngine: model.player.adEngine
                                )
                            }
                        }
                        Button("Fetch Episodes") {
                            Task {
                                await model.fetchEpisodes(itemId: itemId)
                                await loadItem()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .task {
            await loadItem()
        }
        .refreshable {
            await loadItem()
        }
    }

    private func loadItem() async {
        isLoading = true
        errorMessage = nil
        do {
            if let client = model.client {
                item = try await client.item(id: itemId)
            } else if let cached = model.libraryItems.first(where: { $0.id == itemId }) {
                item = cached
            } else {
                throw URLError(.notConnectedToInternet)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct EpisodeDetailView: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode
    @State private var selectedTab: EpisodeTab = .description
    @State private var adsViewMode: AdsViewMode = .active
    @State private var showingTipSheet: Bool = false
    @State private var deletingDownloadKey: String?
    @State private var localScanRecognizer = LiveSpeechRecognizer()

    enum EpisodeTab: String, CaseIterable, Identifiable {
        case description = "Description"
        case ads = "Detected Ads"
        var id: String { rawValue }
    }

    enum AdsViewMode: String, CaseIterable, Identifiable {
        case active = "Active Cuts"
        case compare = "Compare (Server vs Local)"
        var id: String { rawValue }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(Format.shortDate(ms: episode.publishedAt))
                    .foregroundStyle(QuartoTheme.muted)
                Text(episode.title ?? "Episode")
                    .font(QuartoTheme.displayFont)
                if let itemId = episode.libraryItemId {
                    NavigationLink(value: LibraryItem(id: itemId, libraryId: nil, mediaType: "podcast", media: nil, recentEpisode: nil)) {
                        HStack(spacing: 10) {
                            CoverImage(url: model.coverURL(for: itemId), corner: 6)
                                .frame(width: 36, height: 36)
                            Text(episode.showTitle ?? "Show")
                                .foregroundStyle(.white)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(QuartoTheme.muted)
                        }
                    }
                }
                HStack(spacing: 12) {
                    let isCurrent = model.player.itemId == episode.libraryItemId && model.player.episodeId == episode.id
                    let isPlaying = isCurrent && model.player.isPlaying
                    let pillTitle: String = {
                        if isPlaying { return "Pause" }
                        if isCurrent { return "Resume" }
                        if let itemId = episode.libraryItemId,
                           let prog = model.progress(for: itemId, episodeId: episode.id),
                           prog.isFinished != true,
                           let cur = prog.currentTime, cur > 1 {
                            return "Resume (\(Format.remaining(currentTime: cur, duration: episode.resolvedDuration)))"
                        }
                        return Format.duration(episode.resolvedDuration)
                    }()
                    let pillIcon = isPlaying ? "pause.fill" : "play.fill"
                    WhitePlayPill(title: pillTitle, icon: pillIcon) {
                        Task { await model.playEpisode(episode) }
                    }
                    let detectedAds = model.adStore.segments(for: episode.id, title: episode.title)
                    Button {
                        model.adStore.scanEpisodes(
                            [episode],
                            client: model.client,
                            downloads: model.downloads,
                            adEngine: model.player.adEngine
                        )
                    } label: {
                        Image(systemName: detectedAds.isEmpty ? "shield.badge.checkmark" : "shield.fill")
                            .foregroundStyle(detectedAds.isEmpty ? .white : .orange)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(QuartoTheme.chip))
                    }
                    .buttonStyle(.plain)
                    let downloadKey = episode.libraryItemId.map { "\($0):\(episode.id)" }
                    let isDownloaded = episode.libraryItemId.map { model.downloads.isDownloaded(itemId: $0, episodeId: episode.id) } ?? false
                    let isDownloading = downloadKey != nil && model.downloadingKey == downloadKey
                    let isDeleting = downloadKey != nil && deletingDownloadKey == downloadKey
                    if isDownloaded {
                        Button {
                            guard let itemId = episode.libraryItemId, let downloadKey, !isDeleting else { return }
                            deletingDownloadKey = downloadKey
                            Task { @MainActor in
                                await Task.yield()
                                withAnimation {
                                    model.downloads.remove(itemId: itemId, episodeId: episode.id)
                                }
                                deletingDownloadKey = nil
                            }
                        } label: {
                            if isDeleting {
                                ProgressView()
                                    .tint(.red)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(QuartoTheme.chip))
                            } else {
                                Image(systemName: "trash")
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(QuartoTheme.chip))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    } else {
                        Button {
                            Task {
                                guard let itemId = episode.libraryItemId else { return }
                                let item = LibraryItem(id: itemId, libraryId: nil, mediaType: "podcast", media: nil, recentEpisode: episode)
                                await model.download(item: item, episode: episode)
                            }
                        } label: {
                            if isDownloading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(QuartoTheme.chip))
                            } else {
                                Image(systemName: "arrow.down")
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(QuartoTheme.chip))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloading || model.downloadingKey != nil)
                    }
                    CircleIconButton(systemName: "text.badge.plus") {}
                }
                let ads = model.adStore.segments(for: episode.id, title: episode.title)
                let serverCuts = model.adStore.serverSegments(for: episode.id, title: episode.title)
                let localCuts = model.adStore.localSegments(for: episode.id)
                let hasComparison = !serverCuts.isEmpty || !localCuts.isEmpty

                if model.adStore.isScanning && model.adStore.currentScanTitle == (episode.title ?? "Episode") {
                    HStack(spacing: 10) {
                        ProgressView().tint(.orange)
                        Text(model.adStore.scanStatusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Cancel") { model.adStore.cancelScan() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.15)))
                } else {
                    VStack(spacing: 10) {
                        if let error = model.adStore.lastDetectionError,
                           model.adStore.currentScanTitle == (episode.title ?? "Episode") {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: ads.isEmpty ? "shield.badge.checkmark" : "shield.fill")
                                .foregroundStyle(ads.isEmpty ? .white.opacity(0.6) : .orange)
                            Text(ads.isEmpty ? "No ads detected yet" : "\(ads.count) ad breaks active")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ads.isEmpty ? .white : .orange)
                            Spacer()
                            Button {
                                showingTipSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "lightbulb.fill")
                                    Text("Tips")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.yellow.opacity(0.2)))
                                .foregroundStyle(.yellow)
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    _ = await model.adStore.runOnServerAndWait(for: episode)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if model.adStore.isScanning {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "desktopcomputer")
                                    }
                                    Text("4070 Super")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.blue.opacity(0.25)))
                                .foregroundStyle(.white)
                            }
                            .disabled(model.adStore.isScanning)

                            Button {
                                Task {
                                    _ = await model.adStore.detectLocally(
                                        for: episode,
                                        client: model.client,
                                        downloads: model.downloads,
                                        adEngine: model.player.adEngine,
                                        recognizer: localScanRecognizer
                                    )
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if model.adStore.isScanning {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "iphone")
                                    }
                                    Text("Device")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.purple.opacity(0.25)))
                                .foregroundStyle(.white)
                            }
                            .disabled(model.adStore.isScanning)

                            Button {
                                Task {
                                    adsViewMode = .compare
                                    await model.adStore.detectBoth(
                                        for: episode,
                                        client: model.client,
                                        downloads: model.downloads,
                                        adEngine: model.player.adEngine,
                                        recognizer: localScanRecognizer
                                    )
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if model.adStore.isScanning {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "arrow.left.and.right")
                                    }
                                    Text("Compare Both")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.orange.opacity(0.25)))
                                .foregroundStyle(.white)
                            }
                            .disabled(model.adStore.isScanning)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.15)))
                }
                Picker("Section", selection: $selectedTab) {
                    Text("Description").tag(EpisodeTab.description)
                    Text(ads.isEmpty ? "Detected Ads" : "Ads (\(ads.count))").tag(EpisodeTab.ads)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                switch selectedTab {
                case .description:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Format.stripHTML(episode.description))
                            .foregroundStyle(.white.opacity(0.9))
                        if let air = Format.airDate(nil) {
                            Text("Original Air Date: \(air)")
                                .font(.footnote)
                                .foregroundStyle(QuartoTheme.muted)
                        }
                    }
                case .ads:
                    VStack(alignment: .leading, spacing: 14) {
                        if hasComparison {
                            Picker("View Mode", selection: $adsViewMode) {
                                ForEach(AdsViewMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if adsViewMode == .compare && hasComparison {
                            comparisonView(serverCuts: serverCuts, localCuts: localCuts)
                        } else if ads.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "shield.slash")
                                    .font(.system(size: 32))
                                    .foregroundStyle(QuartoTheme.muted)
                                Text("No Ad Breaks Detected")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Choose '4070 Super' for high-speed GPU analysis or 'Device' for on-device recognition.")
                                    .font(.footnote)
                                    .foregroundStyle(QuartoTheme.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(Array(ads.enumerated()), id: \.element.id) { index, ad in
                                    AdSegmentCard(
                                        segment: ad,
                                        index: index + 1,
                                        isCurrentEpisode: model.player.itemId == episode.libraryItemId && model.player.episodeId == episode.id,
                                        currentTime: model.player.currentTime,
                                        onSeek: { target in
                                            if model.player.itemId == episode.libraryItemId && model.player.episodeId == episode.id {
                                                model.player.seek(to: target)
                                            } else {
                                                Task {
                                                    await model.playEpisode(episode)
                                                    model.player.seek(to: target)
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(QuartoTheme.bg)
        .sheet(isPresented: $showingTipSheet) {
            AdTipSheet()
        }
    }
    @ViewBuilder
    private func comparisonView(serverCuts: [AdSegment], localCuts: [AdSegment]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Summary Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Comparison Summary")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.left.and.right")
                        .foregroundStyle(.orange)
                }
                let serverTotal = serverCuts.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
                let localTotal = localCuts.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("4070 Super")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.blue)
                        Text("\(serverCuts.count) breaks (\(Format.durationPrecise(serverTotal)))")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Device")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.purple)
                        Text("\(localCuts.count) breaks (\(Format.durationPrecise(localTotal)))")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
                Divider().overlay(Color.white.opacity(0.1))
                HStack(spacing: 12) {
                    Button {
                        model.adStore.applyCuts(from: .server, for: episode.id)
                    } label: {
                        Text("Use Server Cuts")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.blue))
                            .foregroundStyle(.white)
                    }
                    Button {
                        model.adStore.applyCuts(from: .local, for: episode.id)
                    } label: {
                        Text("Use Device Cuts")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.purple))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))

            // Server Cuts Breakdown
            Text("Desktop Server (RTX 4070 Super)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.top, 6)
            ForEach(Array(serverCuts.enumerated()), id: \.element.id) { index, ad in
                AdSegmentCard(
                    segment: ad,
                    index: index + 1,
                    isCurrentEpisode: model.player.itemId == episode.libraryItemId && model.player.episodeId == episode.id,
                    currentTime: model.player.currentTime,
                    onSeek: { target in model.player.seek(to: target) }
                )
            }

            // Device Cuts Breakdown
            Text("Local Device (Apple Speech)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
                .padding(.top, 10)
            ForEach(Array(localCuts.enumerated()), id: \.element.id) { index, ad in
                AdSegmentCard(
                    segment: ad,
                    index: index + 1,
                    isCurrentEpisode: model.player.itemId == episode.libraryItemId && model.player.episodeId == episode.id,
                    currentTime: model.player.currentTime,
                    onSeek: { target in model.player.seek(to: target) }
                )
            }
        }
    }
}

struct AdTipSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var phrase: String = ""
    @State private var selectedType: TipType = .trigger
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Tip / Rule for Future Runs") {
                    TextField("Cue phrase (e.g. \"here's some ads\")", text: $phrase)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif

                    Picker("Type", selection: $selectedType) {
                        ForEach(TipType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }

                    TextField("Note (optional, e.g. \"Host ad transition\")", text: $note)

                    Button {
                        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.adStore.addTip(
                            phrase: trimmed,
                            type: selectedType,
                            note: note.isEmpty ? nil : note
                        )
                        phrase = ""
                        note = ""
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Save & Sync with 4070 Super")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.orange)
                    }
                    .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Active Tips (\(model.adStore.tips.count))") {
                    if model.adStore.tips.isEmpty {
                        Text("No custom tips yet. Add cues above to guide the detector on future runs.")
                            .font(.footnote)
                            .foregroundStyle(QuartoTheme.muted)
                    } else {
                        ForEach(model.adStore.tips) { tip in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\"\(tip.phrase)\"")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(tipBadge(tip.type))
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(badgeColor(tip.type).opacity(0.25)))
                                        .foregroundStyle(badgeColor(tip.type))
                                }
                                if let note = tip.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(QuartoTheme.muted)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { indices in
                            let idsToDelete = indices.compactMap { index in
                                model.adStore.tips.indices.contains(index) ? model.adStore.tips[index].id : nil
                            }
                            for id in idsToDelete {
                                model.adStore.removeTip(id: id)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(QuartoTheme.bg)
            .navigationTitle("Ad Detection Tips")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func tipBadge(_ type: TipType) -> String {
        switch type {
        case .trigger: "TRIGGER"
        case .exit: "EXIT"
        case .ignore: "IGNORE"
        }
    }

    private func badgeColor(_ type: TipType) -> Color {
        switch type {
        case .trigger: .orange
        case .exit: .green
        case .ignore: .red
        }
    }
}
