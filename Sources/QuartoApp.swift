import SwiftUI

@main
struct QuartoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task {
                    await LogSink.shared.configureFromDefaults()
                    await model.bootstrap()
                    await LogSink.shared.log(level: "info", tag: "app_start", message: "Quarto started")
                }
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 580, minHeight: 620)
        }
        #endif
    }
}
