import Foundation
import Testing
import XCTest
@testable import Quarto

struct FormatTests {
    @Test func durationHours() {
        #expect(Format.duration(4920) == "1h 22m")
    }

    @Test func remaining() {
        #expect(Format.remaining(currentTime: 600, duration: 3600) == "50m left")
    }

    @Test func stripHTML() {
        let raw = "<div>Hello<br/>world</div>"
        #expect(Format.stripHTML(raw).contains("Hello"))
        #expect(!Format.stripHTML(raw).contains("<"))
    }
}

struct DecodingTests {
    @Test func loginUser() throws {
        let json = """
        {
          "user": {
            "id": "root",
            "username": "root",
            "token": "abc",
            "mediaProgress": [{
              "id": "p1",
              "libraryItemId": "li1",
              "duration": 100,
              "progress": 0.5,
              "currentTime": 50,
              "isFinished": false
            }]
          },
          "userDefaultLibraryId": "lib1"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: json)
        #expect(decoded.user.bearerToken == "abc")
        #expect(decoded.user.mediaProgress.count == 1)
    }

    @Test func prefersAccessToken() throws {
        let json = """
        {"user":{"id":"u","username":"u","token":"old","accessToken":"new","refreshToken":"ref","mediaProgress":[]},"userDefaultLibraryId":"lib1"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: json)
        #expect(decoded.user.bearerToken == "new")
        #expect(decoded.user.refreshToken == "ref")
    }

    @Test func jwtExpiry() {
        let payload = Data("{\"exp\":1000}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = "aaa.\(payload).sig"
        #expect(JWT.expiration(of: token)?.timeIntervalSince1970 == 1000)
        #expect(JWT.needsRefresh(token))
    }

    @Test func legacyCredentialsDecode() throws {
        let json = """
        {"serverURL":"https://abs.example","token":"legacy","username":"u","userId":"id"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionCredentials.self, from: json)
        #expect(decoded.accessToken == "legacy")
    }

    @Test func libraries() throws {
        let json = """
        {"libraries":[
          {"id":"a","name":"Books","mediaType":"book","displayOrder":1},
          {"id":"b","name":"Pods","mediaType":"podcast","displayOrder":2}
        ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LibrariesResponse.self, from: json)
        #expect(decoded.libraries[1].isPodcast)
    }

    @Test func emptyPersonalizedHandling() {
        let data = "Not Found".data(using: .utf8)!
        let sections = (try? JSONDecoder().decode([PersonalizedSection].self, from: data)) ?? []
        #expect(sections.isEmpty)
    }

    @Test @MainActor func appModelLibrarySwitchAndSettings() async {
        let model = AppModel()
        model.libraries = [
            Library(id: "lib1", name: "Books", mediaType: "book", displayOrder: 1),
            Library(id: "lib2", name: "Podcasts", mediaType: "podcast", displayOrder: 2)
        ]
        model.selectedLibrary = model.libraries[0]
        #expect(model.selectedLibrary?.id == "lib1")
        #expect(model.selectedLibrary?.isPodcast == false)

        await model.selectLibrary(model.libraries[1])
        #expect(model.selectedLibrary?.id == "lib2")
        #expect(model.selectedLibrary?.isPodcast == true)

        model.showSettings = true
        #expect(model.showSettings == true)
    }

}

@MainActor
final class StartupScreenTests: XCTestCase {
    func testStartupPrefersPodcastsOverDefaultBooks() {
        let libraries = [
            Library(id: "books", name: "Books", mediaType: "book", displayOrder: 1),
            Library(id: "podcasts", name: "Podcasts", mediaType: "podcast", displayOrder: 2)
        ]

        let selected = AppModel.startupLibrary(
            in: libraries,
            defaultLibraryID: "books",
            cachedLibraryID: nil
        )

        XCTAssertEqual(selected?.id, "podcasts")
    }
}
