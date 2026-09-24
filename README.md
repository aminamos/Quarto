# Quarto

Native SwiftUI iOS client for a self-hosted [Audiobookshelf](https://www.audiobookshelf.org) server.

Independent project. Not affiliated with Audiobookshelf or with Still.

Uses the [public Audiobookshelf HTTP API](https://api.audiobookshelf.org/) only. Original UI and code.

## Requirements

- iOS 18
- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- A running Audiobookshelf server

## Cloud builds (no Xcode needed)

A GitHub Actions workflow builds and uploads to TestFlight — trigger it from
anywhere: GitHub.com > aminamos/Quarto > Actions > "TestFlight" > Run workflow
(the GitHub mobile app works too).

One-time setup: create an App Store Connect API team key at App Store Connect >
Users and Access > Integrations and give it the **Admin** role. App Manager and
Developer keys cannot create the Apple Distribution certificate and the App Store
provisioning profile that the "Export IPA" step needs, so the build stops there
with `Cloud signing permission error` / `No profiles for 'codes.amos.quarto'
were found`. An API key's access level can't be edited after creation, so revoke
the old key and generate a new Admin one. Then add three repo secrets
(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` = the .p8 contents) and push
`.github/workflows/testflight.yml`. Full steps — including the manual-signing
alternative for accounts that can't hand out an Admin key — are in the workflow
file header.

## Build

`Quarto.xcodeproj` is a generated project derived from `project.yml`.

```sh
xcodegen generate
xcodebuild -scheme Quarto -destination 'generic/platform=iOS Simulator' build
```

Or generate and open it in Xcode:

```sh
xcodegen generate
open Quarto.xcodeproj
```

Sign with your team. Default bundle id is `codes.amos.quarto`.

## What works

- Username/password login; token in Keychain
- Library switcher (books / podcasts / custom libraries)
- Book home: browse rows + continue listening
- Podcast home: show strip, Latest / Shows / Continue tabs, episode list
- Show and episode pages
- Multi-select downloads for episodes from Latest or a show's full episode list
- Playback via `AVPlayer`, lock-screen controls, progress sync
- Sponsor/ad break detection on the device or on the self-hosted backend, then
  automatic skipping during playback (`Skip Sponsor Break`)
- Skip Silence (Overcast-style pause compression) for local and streaming episodes
- Share a detected ad-break list as JSON, or import one a friend sent you
- HTTP self-hosted servers (ATS exception)

## Ad detection backend

Detection runs against the sibling repo
[`aminamos/quarto-backend`](https://github.com/aminamos/quarto-backend) (private).
It is **detection-only**: a job returns break timestamps and leaves the audio
untouched — nothing is re-encoded and library files are never rewritten. Quarto
skips the breaks at playback time, on the device, and the Skipped/Breaks panel in
the player is what you tune.

Default backend URL: `http://100.121.101.70:5055`, editable under
Settings > Sponsor & Ad Detection > Backend URL.

The backend's `ad_server.py` serves:

| Route | Purpose |
| --- | --- |
| `GET /api/health` | liveness probe |
| `GET /api/plans` | finished detection plans, keyed by episode title |
| `GET /api/sync` | whole plan snapshot, for "Sync All Plans from Backend" |
| `POST /api/detect` | queue an episode for detection |
| `GET /api/tips`, `POST /api/tips` | read / add detector cue phrases |
| `POST /api/log` | remote diagnostic log sink |
| `POST /api/clear-cache` | drop the backend's cached plans |

Those route names and JSON shapes are the app-facing contract.

On-device detection and skip-silence analysis live in this repo:
`Sources/AdSkipEngine.swift` over the prebuilt Rust core in
`Frameworks/QuartoAdSkip.xcframework`, plus `Sources/SilenceDetector.swift`.

## Not in this tree

CarPlay, widgets, ebook reader, OIDC, custom HTTP headers, home-section customization.
