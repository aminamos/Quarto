import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.credentials == nil {
                LoginView()
            } else if model.selectedLibrary == nil {
                StartupLoadingView()
            } else {
                MainShell()
            }
        }
        .background(QuartoTheme.bg.ignoresSafeArea())
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

struct StartupLoadingView: View {
    @Environment(AppModel.self) private var model
    @State private var showingDownloads = false

    var body: some View {
        VStack(spacing: 16) {
            if model.isLoading {
                ProgressView()
                    .tint(.orange)
                Text("Loading Podcasts…")
                    .font(.headline)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Unable to Connect")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("Could not reach your Audiobookshelf server.")
                    .font(.subheadline)
                    .foregroundStyle(QuartoTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button("Retry") {
                        Task { await model.bootstrap() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    if !model.downloads.files.isEmpty {
                        Button {
                            if let cached = model.libraries.first {
                                model.selectedLibrary = cached
                            } else {
                                model.selectedLibrary = Library(
                                    id: "offline",
                                    name: "Downloaded Content",
                                    mediaType: "podcast",
                                    displayOrder: 0
                                )
                            }
                        } label: {
                            Label("Continue Offline (\(model.downloads.files.count))", systemImage: "arrow.down.circle")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    Button {
                        showingDownloads = true
                    } label: {
                        Label("View Downloaded Content", systemImage: "folder")
                    }
                    .font(.subheadline)
                    .foregroundStyle(QuartoTheme.muted)

                    Button("Sign In / Change Server") {
                        model.logout()
                    }
                    .font(.subheadline)
                    .foregroundStyle(QuartoTheme.muted)
                    .padding(.top, 4)
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuartoTheme.bg.ignoresSafeArea())
        .sheet(isPresented: $showingDownloads) {
            NavigationStack {
                BrowseDestinationView(route: .downloaded)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingDownloads = false }
                        }
                    }
            }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("Quarto")
                .font(QuartoTheme.titleFont)
            Text("Connect to your Audiobookshelf server.")
                .foregroundStyle(QuartoTheme.muted)
            field("Server URL", text: $server, prompt: "https://abs.example.com")
            field("Username", text: $username, prompt: "username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(QuartoTheme.card))
            Button {
                Task { await model.login(server: server, username: username, password: password) }
            } label: {
                Text(model.isLoading ? "Connecting…" : "Sign In")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .disabled(model.isLoading)
            Spacer()
        }
        .padding(28)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        let field = TextField(title, text: text, prompt: Text(prompt))
            .autocorrectionDisabled()
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(QuartoTheme.card))
        #if os(iOS)
        return field
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #else
        return field
        #endif
    }
}

struct MainShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.selectedLibrary?.isPodcast == true {
                    PodcastHomeView()
                } else {
                    BookHomeView()
                }
            }
            .navigationDestination(for: LibraryItem.self) { item in
                ItemDetailView(itemId: item.id)
            }
            .navigationDestination(for: PodcastEpisode.self) { episode in
                EpisodeDetailView(episode: episode)
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDestinationView(route: route)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.player.itemId != nil {
                MiniPlayerView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: Bindable(model).showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Bindable(model).showPlayer) {
            PlayerSheet()
                .presentationDetents([.large])
        }
    }
}
