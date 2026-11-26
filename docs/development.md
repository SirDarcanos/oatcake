# Development

How to build Oatcake, try a build without touching your own data, and find your way around the
code. [CONTRIBUTING.md](../CONTRIBUTING.md) covers pull requests.

## Build from source

Needs Xcode's command line tools (`xcode-select --install`, Swift 6.2 or later); Xcode itself
isn't needed.

```sh
swift build                  # debug build of everything
swift test                   # the core's tests (Tests/OatcakeCoreTests, a file for each area)
Scripts/bundle.sh            # build/Oatcake.app, release build, recorder and llama.cpp inside
Scripts/bundle.sh debug      # the same, debug build
```

`Scripts/bundle.sh` signs with the "Oatcake Release" certificate when that's in your keychain,
and ad-hoc otherwise. macOS ties the recorder's microphone and system-audio permission to the
signature: an ad-hoc build is a new app to macOS every time (so it asks again), and only a
release-signed copy can update itself. `OATCAKE_SIGN_IDENTITY` and `OATCAKE_SIGN_KEYCHAIN` choose
another identity or keychain, `OATCAKE_REQUIRE_SIGNING=1` stops rather than sign ad-hoc, and
`OATCAKE_BIN` names a folder of binaries already built (the Release workflow uses these). The
icon is `assets/icon.svg`; `assets/Oatcake.icns` is built from `assets/icon.png` with `iconutil`.

`Scripts/bundle.sh` also puts llama.cpp's server in the app: one fixed build from llama.cpp's
releases, downloaded once into `.build/llama` and checked against its SHA-256. A copy run straight
from `swift build` has no llama.cpp beside it; point `OATCAKE_LLAMA_DIR` at a folder that holds
`llama-server` and its libraries (`build/Oatcake.app/Contents/Resources/llama` will do).

With only the command line tools, SwiftUI's `@State` macro isn't available (its plugin ships with
Xcode), so views use the `State` property wrapper through the `ViewState` alias.

## Trying a build

To try a build without touching your own recordings, settings and voiceprints, point it at
another data folder (and set a different Meetings folder in its Settings):

```sh
open -n --env OATCAKE_DATA_DIR=/tmp/oatcake-test build/Oatcake.app
```

Environment variables that help when trying things out:

- `OATCAKE_DATA_DIR` points a development copy at another data folder, with its own saved calendar
  address. A copy started with it leaves the login Keychain alone.
- `OATCAKE_LLAMA_DIR` names the folder llama.cpp's server is in, for a copy that isn't a bundle.
- `OATCAKE_CALENDAR_URL` supplies a calendar address without saving the URL or an on-disk feed cache
  (a local `.ics` served over HTTP will do). Oatcake keeps the calendar’s local badge ID separately
  from private settings so saved meetings can still recognise it after a restart.
- `OATCAKE_CALL_APPS` names a file listing the apps to treat as on a call, one per line, so the
  call notice and the automatic stop can be tried without making a call.
- `OATCAKE_UPDATE_FEED` points the updater at another `latest.json` (see
  [Releasing](releasing.md)).

A development copy has the same bundle ID as an installed Oatcake, so macOS can hand a click on
one of its notification buttons to the installed copy, which then acts on your own data. Leave a
test copy's notifications alone.

## Layout

- `Sources/OatcakeRecorder/` — system-audio + mic recorder (helper app)
- `Sources/RecorderContract/` — the files the recorder and Oatcake pass between them, and the
  check that the recorder only records for Oatcake
- `Sources/OatcakeCore/` — recordings, speech pipeline, voiceprints, the language model and its
  download, summaries and templates, meeting folders, renaming speakers, calendar and its private
  address, Granola and Quill imports, Ask, updates, the MCP server
- `Sources/Oatcake/` — the app (SwiftUI); `--analyse` runs the analysis helper, `--live` the live
  transcript's, `--menu-bar` the menu bar item's and `--mcp` the MCP server other apps start
- `Tests/OatcakeCoreTests/` — tests, a file for each area, including the calendar against
  ical.js's output
- `Scripts/` — bundling, versioning, signing `latest.json`
