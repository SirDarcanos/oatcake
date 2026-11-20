# Contributing to Oatcake

Thanks for helping. Oatcake records people's calls, so a change is judged first on whether it keeps
their recordings, notes and voices safe and on their Mac, and then on whether it's easy to use.

## Before you start

For anything bigger than a small fix, open an issue first and say what you'd like to change, so we
can agree on the approach before you spend time on it. [What's next](docs/whats-next.md) lists what
we'd like to add.

## Setting up

You need an Apple Silicon Mac on macOS 15 or later, and Xcode's command line tools with Swift 6.2
or later (`xcode-select --install`). Xcode itself isn't needed.

```sh
swift build          # debug build of everything
swift test           # the core's tests
Scripts/bundle.sh    # build/Oatcake.app, with the recorder and llama.cpp inside
```

[Development](docs/development.md) has the details, including how to
[try a build](docs/development.md#trying-a-build) without touching your own recordings, settings
and voiceprints: start it with `OATCAKE_DATA_DIR` pointing at another folder, and choose another
Meetings folder in its Settings. A development copy shares an installed Oatcake's bundle ID, so
leave its notification buttons alone: a click can reach the installed copy.

If `swift test` fails with "plugin for module 'TestingMacros' not found", the build folder is
stale: run `rm -rf .build` and try again.

## Making a change

- Branch from `trunk`, named for what the branch does: `add/…` for something new, `fix/…` for a
  fix, `chore/…` for anything else.
- Put logic in `Sources/OatcakeCore`, where it can be tested, and keep `Sources/Oatcake` to the
  app's windows and menus. Add or change tests in `Tests/OatcakeCoreTests` (a file for each area)
  for what you change.
- Without Xcode, SwiftUI's `@State` macro isn't available, so views use the `ViewState` alias.
- Write comments that say why, not what.
- Anything the app says to people (buttons, hints, notifications, errors) is in plain British
  English: say what happens and what to do next, without jargon.
- Use made-up names in code, tests, fixtures, docs and screenshots: John Doe, Jane Doe, John
  Smith, Jane Smith, Joe Bloggs, Richard Roe and the like. Never use a real person's name, and
  never commit a real recording, transcript or calendar.
- A change people can see or use goes in the docs in the same pull request: the page in
  [docs/](docs/) that describes it, and [Features](docs/features.md) if it adds or removes a
  feature.

## Commits and pull requests

- Write each commit subject as a sentence about what changes for the person using Oatcake, such
  as "A voice that isn't part of the call can be left out in Who's who". Leave out prefixes like
  `feat:`.
- Keep a pull request to one change, and say what it does, why, and how you tested it.
- For a change you can see, add before and after screenshots, taken with a test copy and made-up
  names.
- The Test workflow builds everything, runs the tests and checks the scripts parse on every pull
  request. A pull request from a fork waits for a maintainer to start its test run.
- An automated review comments on each pull request. Answer or fix what it finds before asking
  for a merge.
- Maintainers merge with a merge commit.

## Releases

Releases are made by maintainers from `trunk`: see [Releasing](docs/releasing.md).

## Licence

Oatcake is GPL-3.0-or-later. By contributing, you agree that your contribution is licensed under
the same terms ([LICENSE](LICENSE)). Code adapted from elsewhere needs a licence that allows it,
and a note in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
