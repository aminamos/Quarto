# Quarto

Native SwiftUI iOS client for a self-hosted [Audiobookshelf](https://www.audiobookshelf.org) server.

Independent project. Not affiliated with Audiobookshelf or with Still.

Uses the [public Audiobookshelf HTTP API](https://api.audiobookshelf.org/) only. Original UI and code.

## Requirements

- iOS 18
- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- A running Audiobookshelf server

## Build

`Quarto.xcodeproj` is a generated project derived from `project.yml`.

```sh
xcodegen generate
./build-aa17.sh
```

Or:

```sh
xcodegen generate
xcodebuild -scheme Quarto -destination 'generic/platform=iOS Simulator' build
```

Sign with your team. Default bundle id is `codes.amos.quarto`.

## What works

- Username/password login; token in Keychain
- Library switcher (books / podcasts / custom libraries)
- Book home: browse rows + continue listening
- Podcast home: show strip, Latest / Continue, episode list
- Show and episode pages
- Playback via `AVPlayer`, lock-screen controls, progress sync
- Offline download of the current audio file
- HTTP self-hosted servers (ATS exception)

## Not in this tree

CarPlay, widgets, ebook reader, OIDC, custom HTTP headers, home-section customization.
