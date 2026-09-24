import Foundation
import Testing

/// App Store validation rejects a build whose bundle ships without an app icon
/// or without `CFBundleIconName` (ITMS-90022/90023/90713), and that failure only
/// surfaces by email after a TestFlight upload. Assert it in CI instead, where a
/// regression is caught in the unit-test job before an archive is even made.
struct AppIconTests {
    @Test func appBundleShipsACompiledAppIcon() throws {
        let app = try #require(
            [Bundle.main, Bundle(identifier: "codes.amos.quarto")]
                .compactMap { $0 }
                .first { $0.bundleURL.pathExtension == "app" },
            "no .app bundle found: the iOS app has to host these tests"
        )
        #expect(
            app.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon",
            "CFBundleIconName must name the asset catalog's icon set (ITMS-90713)"
        )
        #expect(
            app.url(forResource: "Assets", withExtension: "car") != nil,
            "no compiled asset catalog in the bundle, so the app would ship without an icon"
        )
    }

    @Test func sourceAssetCatalogHasASingleSizeIcon() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        let data = try Data(contentsOf: catalog)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = try #require(json?["images"] as? [[String: Any]])
        let icon = try #require(images.first)
        #expect(icon["filename"] as? String == "AppIcon-1024.png")
        #expect(icon["size"] as? String == "1024x1024")
        #expect(icon["platform"] as? String == "ios")
    }
}
