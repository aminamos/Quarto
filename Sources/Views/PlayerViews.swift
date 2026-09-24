import SwiftUI
import UniformTypeIdentifiers

struct CoverImage: View {
    let url: URL?
    var corner: CGFloat = 8

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                RoundedRectangle(cornerRadius: corner)
                    .fill(QuartoTheme.card)
                    .overlay {
                        Image(systemName: "waveform")
                            .foregroundStyle(QuartoTheme.muted)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.showPlayer = true
            } label: {
                HStack(spacing: 10) {
                    CoverImage(url: model.player.coverURL, corner: 8)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.player.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(QuartoTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.player.skip(seconds: -10)
            } label: {
                Image(systemName: "gobackward.10")
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button {
                model.player.toggle()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(white: 0.12)))
    }

    private var status: String {
        let remaining = model.player.remainingText
        let pct = Int(model.player.progress * 100)
        if remaining.isEmpty { return model.player.author }
        return "\(remaining) · \(pct)%"
    }
}

struct PlayerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: PlayerTab = .player
    @State private var shareURL: URL?
    @State private var showImporter = false
    @State private var importMessage: String?

    enum PlayerTab: String, CaseIterable, Identifiable {
        case player = "Now Playing"
        case description = "Description"
        case ads = "Detected Ads"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)

                let ads = model.player.detectedAdSegments
                let hasDescription = model.player.episodeDescription != nil && !(model.player.episodeDescription?.isEmpty ?? true)
                let hasExtra = hasDescription || !ads.isEmpty
                if hasExtra {
                    Picker("View", selection: $selectedTab) {
                        Text("Player").tag(PlayerTab.player)
                        if hasDescription {
                            Text("Description").tag(PlayerTab.description)
                        }
                        if !ads.isEmpty {
                            Text("Ads (\(ads.count))").tag(PlayerTab.ads)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch selectedTab {
                case .player:
                    playerContent
                case .description:
                    descriptionContent
                case .ads:
                    adsContent(ads: ads)
                }
            }
            .padding(24)
            .background(QuartoTheme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            validateTab()
        }
        .onChange(of: model.player.episodeDescription) { _, _ in
            validateTab()
        }
        .onChange(of: model.player.detectedAdSegments) { _, _ in
            validateTab()
        }
    }

    private func validateTab() {
        let ads = model.player.detectedAdSegments
        let hasDescription = model.player.episodeDescription != nil && !(model.player.episodeDescription?.isEmpty ?? true)
        let hasExtra = hasDescription || !ads.isEmpty
        if !hasExtra {
            selectedTab = .player
        } else if selectedTab == .description && !hasDescription {
            selectedTab = .player
        } else if selectedTab == .ads && ads.isEmpty {
            selectedTab = .player
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        VStack(spacing: 20) {
            CoverImage(url: model.player.coverURL, corner: 16)
                .frame(width: 260, height: 260)
            Text(model.player.title)
                .font(QuartoTheme.displayFont)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(model.player.author)
                .foregroundStyle(QuartoTheme.muted)
                .lineLimit(1)
            Slider(
                value: Binding(
                    get: { model.player.progress },
                    set: { model.player.seek(fraction: $0) }
                )
            )
            .tint(.white)
            HStack {
                Text(Format.timestamp(model.player.currentTime))
                Spacer()
                Text(model.player.remainingText)
            }
            .font(.caption)
            .foregroundStyle(QuartoTheme.muted)
            if let activeAd = model.player.activeAdSegment {
                Button {
                    model.player.skipAd()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.fill")
                        Text("Skip Sponsor Break (\(Int(activeAd.endTime - model.player.currentTime))s)")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.orange.opacity(0.85)))
                    .foregroundStyle(.white)
                }
            }
            HStack(spacing: 36) {
                Button { model.player.skip(seconds: -10) } label: {
                    Image(systemName: "gobackward.10").font(.title)
                }
                Button { model.player.toggle() } label: {
                    Image(systemName: model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                }
                Button { model.player.skip(seconds: 30) } label: {
                    Image(systemName: "goforward.30").font(.title)
                }
            }
            .foregroundStyle(.white)
            HStack {
                Text("Speed \(String(format: "%.2fx", model.player.rate))")
                Slider(value: Bindable(model.player).rate, in: 0.5...3, step: 0.05)
            }
            .foregroundStyle(.white)
            Toggle(isOn: Bindable(model.player).skipSilence) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.minus")
                    Text("Skip Silence")
                }
                .font(.subheadline)
            }
            .toggleStyle(.switch)
            .tint(.orange)
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var descriptionContent: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.player.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(model.player.author)
                        .font(.subheadline)
                        .foregroundStyle(QuartoTheme.muted)
                    Divider().overlay(Color.white.opacity(0.1))
                    if let desc = model.player.episodeDescription, !desc.isEmpty {
                        Text(Format.stripHTML(desc))
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        Text("No description available for this episode.")
                            .font(.subheadline)
                            .foregroundStyle(QuartoTheme.muted)
                            .padding(.top, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            miniControls
        }
    }

    @ViewBuilder
    private func adsContent(ads: [AdSegment]) -> some View {
        VStack(spacing: 16) {
            HStack {
                if let shareURL {
                    ShareLink(item: shareURL, preview: SharePreview("Ad breaks", image: Image(systemName: "scissors"))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                Button {
                    importMessage = nil
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            .font(.subheadline)
            if let importMessage {
                Text(importMessage)
                    .font(.footnote)
                    .foregroundStyle(QuartoTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ads.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "shield.slash")
                                .font(.system(size: 36))
                                .foregroundStyle(QuartoTheme.muted)
                            Text("No Ad Breaks Detected")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Quarto's on-device speech engine analyzes audio live during playback to detect ads.")
                                .font(.footnote)
                                .foregroundStyle(QuartoTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(ads.enumerated()), id: \.element.id) { index, ad in
                                AdSegmentCard(
                                    segment: ad,
                                    index: index + 1,
                                    isCurrentEpisode: true,
                                    currentTime: model.player.currentTime,
                                    onSeek: { target in
                                        model.player.seek(to: target)
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            miniControls
        }
        .onAppear { refreshShareFile(ads: ads) }
        .onChange(of: ads) { _, newAds in refreshShareFile(ads: newAds) }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let (title, added) = try model.adStore.importSharedList(from: url)
                    importMessage = added > 0
                        ? "Imported \(added) ad break\(added == 1 ? "" : "s") for \(title)."
                        : "No new ad breaks in that file."
                } catch {
                    importMessage = "Could not import that file."
                }
            case .failure:
                importMessage = "Could not import that file."
            }
        }
    }

    private func refreshShareFile(ads: [AdSegment]) {
        let author = model.player.author.trimmingCharacters(in: .whitespacesAndNewlines)
        shareURL = model.adStore.exportSharedList(
            episodeId: model.player.episodeId,
            episodeTitle: model.player.title,
            showTitle: author.isEmpty ? nil : author,
            duration: model.player.duration > 0 ? model.player.duration : nil
        )
    }

    private var miniControls: some View {
        HStack(spacing: 20) {
            Button { model.player.skip(seconds: -10) } label: {
                Image(systemName: "gobackward.10").font(.title2)
            }
            Button { model.player.toggle() } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            Button { model.player.skip(seconds: 30) } label: {
                Image(systemName: "goforward.30").font(.title2)
            }
            Spacer()
            Text("\(Format.timestamp(model.player.currentTime)) / \(Format.duration(model.player.duration))")
                .font(.caption)
                .foregroundStyle(QuartoTheme.muted)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let credentials = model.credentials {
                    Section("Server") {
                        LabeledContent("URL", value: credentials.serverURL)
                        LabeledContent("User", value: credentials.username)
                        Text("Password stays in Keychain. Access tokens last about an hour. Quarto refreshes them with the 30-day refresh token, then signs in again if that fails.")
                            .font(.footnote)
                            .foregroundStyle(QuartoTheme.muted)
                    }
                }
                Section("Sponsor & Ad Detection") {
                    Toggle("Automatically Skip Ads", isOn: Bindable(model.player).autoSkipAds)
                    Text(model.player.autoSkipAds ? "Ads skip automatically during playback." : "Ads will show an orange 'Skip Sponsor Break' button without jumping automatically.")
                        .font(.footnote)
                        .foregroundStyle(QuartoTheme.muted)
                    Toggle("Detect on Backend (RTX 4070 Super)", isOn: Bindable(model.adStore).useServerDetection)
                    if model.adStore.useServerDetection {
                        HStack {
                            Text("Backend URL")
                            Spacer()
                            TextField("URL", text: Bindable(model.adStore).serverDetectionURL)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(QuartoTheme.muted)
#if os(iOS)
                                .textInputAutocapitalization(.never)
#endif
                                .autocorrectionDisabled()
                        }
                    }
                    Button {
                        Task {
                            _ = await model.adStore.syncAllPlansFromDesktop()
                        }
                    } label: {
                        HStack {
                            if model.adStore.isSyncing {
                                ProgressView().tint(.orange)
                                    .padding(.trailing, 4)
                                Text("Syncing from Backend...")
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Sync All Plans from Backend")
                            }
                        }
                    }
                    .disabled(model.adStore.isSyncing)

                    if let count = model.adStore.lastSyncCount, let date = model.adStore.lastSyncDate {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Synced \(count) plans (\(Format.relative(ms: date.timeIntervalSince1970 * 1000)))")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    LabeledContent("Desktop Plans Cached", value: "\(model.adStore.titlePlans.count) episodes")
                    Text("Runs detection on quarto-backend (RTX 4070 Super) with automatic fallback to on-device recognition. The backend only detects breaks and returns their timestamps - nothing is re-encoded; Quarto skips the breaks during playback on this device.")
                        .font(.footnote)
                        .foregroundStyle(QuartoTheme.muted)
                }
                Section("Playback") {
                    Toggle("Skip Silence", isOn: Bindable(model.player).skipSilence)
                    Text("Smart Speed style: Quarto measures quiet stretches in the episode audio and jumps past the long ones while you listen.")
                        .font(.footnote)
                        .foregroundStyle(QuartoTheme.muted)
                    if model.player.skipSilence {
                        if model.player.isScanningSilence {
                            HStack(spacing: 8) {
                                ProgressView().tint(.orange)
                                Text("Analyzing pauses...")
                                    .font(.footnote)
                                    .foregroundStyle(QuartoTheme.muted)
                            }
                        } else if model.player.itemId != nil {
                            LabeledContent("Pauses Found", value: "\(model.player.silenceSegments.count)")
                        }
                    }
                }
                Section("Debug Logs") {
                    Toggle("Enable Log Sink", isOn: Bindable(model.adStore).useLogSink)
                    if model.adStore.useLogSink {
                        HStack {
                            Text("Sink URL")
                            Spacer()
                            TextField("URL", text: Bindable(model.adStore).logSinkURL)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(QuartoTheme.muted)
#if os(iOS)
                                .textInputAutocapitalization(.never)
#endif
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("Sink Token")
                            Spacer()
                            SecureField("Token", text: Bindable(model.adStore).logSinkToken)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(QuartoTheme.muted)
#if os(iOS)
                                .textInputAutocapitalization(.never)
#endif
                                .autocorrectionDisabled()
                        }
                    }
                    Text("Streams diagnostic logs to your remote D1 sink worker.")
                        .font(.footnote)
                        .foregroundStyle(QuartoTheme.muted)
                }
                Section("Downloads & Storage") {
                    LabeledContent("Downloaded Audio", value: "\(model.downloads.files.count) files (\(model.downloads.formattedTotalSize))")
                    Button("Delete All Downloaded Episodes", role: .destructive) {
                        model.downloads.clearAll()
                    }
                    .disabled(model.downloads.files.isEmpty)
                    Button("Clean Temporary Ad Scans") {
                        model.downloads.cleanTemporaryAdScans()
                    }
                }
                Section("Ad Detection Cache") {
                    Button("Clear Local Ad Cache") {
                        model.adStore.clearLocalCache()
                    }
                    Button("Clear Backend Cache") {
                        Task { await model.adStore.clearServerCache() }
                    }
                    Button("Clear All Caches (Local & Remote)", role: .destructive) {
                        Task { await model.adStore.clearAllCaches() }
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        model.logout()
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(QuartoTheme.bg)
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .preferredColorScheme(.dark)
    }
}
