# Oatcake

A Mac app that records a call, transcribes it on this Mac, tells the other voices apart,
lets you check who said what, and writes a summary built around the notes you took
during the call. The speech models and the language model run on your Mac, so nothing from a call
leaves it, unless you point Oatcake at a model server of your own on your network.

## What it does

- **Records a call**: your microphone and everything the Mac plays, with notes you type during
  it, each stamped with its time, and a [live transcript](docs/how-it-works.md#live-transcript)
  beside them. It [notices calls](docs/how-it-works.md#calls-are-noticed) starting and ending.
- **Works from your calendar**: the next calls on Home and in the sidebar and the
  [menu bar](docs/how-it-works.md#the-menu-bar), a reminder before each, **Join the call**, prep
  notes, and a folder for each recurring meeting. [Calendars](docs/settings.md#calendars)
- **Transcribes and tells the voices apart on this Mac**, and recognises people it has heard
  before. [Process](docs/how-it-works.md#2-process)
- **Who's who**: a [check of who said what](docs/how-it-works.md#3-review-whos-who) before a call
  is saved, or [saving straight away](docs/how-it-works.md#saving-without-whos-who) and naming
  the voices later. [Rename People](docs/how-it-works.md#rename-people) puts a name right in a
  saved meeting.
- **Summaries and to-dos** written by a language model on this Mac, steered by your notes, with
  your own instructions and [templates](docs/how-it-works.md#regenerate-and-summary-templates).
  [To-dos](docs/how-it-works.md#to-dos) from every meeting gather on one page, or can be turned
  off.
- **Meetings as folders** of Markdown in a folder you choose, organised by dragging, searched, and
  copied or shared formatted. [Save](docs/how-it-works.md#4-save)
- **[Ask](docs/how-it-works.md#5-ask)** questions about a meeting or across them.
- **[Imports](docs/importing.md)** from Granola and Quill, and
  **[updates itself](docs/updates.md)** from signed releases.

[Features](docs/features.md) lists everything Oatcake does.

## Install

Needs an Apple Silicon Mac on macOS 15 or later. Paste this into Terminal:

```sh
curl -fsSL https://github.com/a8cteam51/oatcake/releases/latest/download/install.sh | sh
```

[Install](docs/install.md) covers installing by hand, what the installer checks, the first
recording's permissions and the model downloads, and what to tell the people on your calls.

## Documentation

- [Features](docs/features.md): everything Oatcake does, in one list.
- [Install](docs/install.md): the Terminal line, installing by hand, the
  [first recording](docs/install.md#first-recording) and
  [before you record](docs/install.md#before-you-record).
- [How it works](docs/how-it-works.md): the pipeline, [the window](docs/how-it-works.md#the-window),
  and each step: [record](docs/how-it-works.md#1-record),
  [process](docs/how-it-works.md#2-process), [review](docs/how-it-works.md#3-review-whos-who),
  [save](docs/how-it-works.md#4-save) and [ask](docs/how-it-works.md#5-ask).
- [Keyboard shortcuts](docs/keyboard-shortcuts.md), and the menus they're in.
- [Settings](docs/settings.md), pane by pane: [General](docs/settings.md#general),
  [Calendars](docs/settings.md#calendars), [People](docs/settings.md#people),
  [Models](docs/settings.md#models), [Summaries](docs/settings.md#summaries),
  [Storage](docs/settings.md#storage) and [Updates](docs/settings.md#updates).
- [Importing from Granola and Quill](docs/importing.md).
- [Speech and language models](docs/models.md): [speech models](docs/models.md#speech-models),
  [the language model](docs/models.md#language-model) and [accuracy](docs/models.md#accuracy).
- [Updates](docs/updates.md): how Oatcake checks for and installs a new release.
- [Security](docs/security.md): what stays on your Mac, and what's checked.
- [Moving from the Electron version](docs/moving-from-electron.md) (0.3 and earlier).
- [What's next](docs/whats-next.md): what we'd like to add.
- [Development](docs/development.md): [building from source](docs/development.md#build-from-source),
  [trying a build](docs/development.md#trying-a-build) and the
  [code's layout](docs/development.md#layout).
- [Releasing](docs/releasing.md): versioning, the Release workflow and its secrets.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

GPL-3.0-or-later ([LICENSE](LICENSE)). The recorder's audio tap and the echo check are adapted from
OpenWhispr, under its MIT license; FluidAudio is Apache-2.0; llama.cpp, inside the app, is MIT
([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
