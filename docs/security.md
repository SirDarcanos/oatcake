# Security

- Every path the window acts on is checked to stay inside the Meetings folder or the recordings
  folder. The Meetings folder itself is only changed through the folder picker. The app itself
  never records: the recorder app captures audio on its own.
- Summaries and answers are drawn as Markdown with any HTML shown as text. Links in Ask's answers
  to anything but a meeting are shown as text, not made clickable.
- Speech models are fetched from pinned commits (see [Speech models](models.md#speech-models)).
- The language model and the program that runs it are fixed builds, each checked against its
  SHA-256 before use. Its server listens only on this Mac's own address, at a port picked each
  time, behind a key made up each time, and is told nothing but text: it can't open files, run
  commands or reach the network through Oatcake. A model server of your own has to be at a local
  address (see [Language model](models.md#language-model)).
- What's said on a call ends up in front of the model, so its replies are treated as text from a
  stranger: a suggested name is only offered if it was said in the call, to-dos and Ask's first
  step are held to a fixed shape, and links are handled as above.
- Updates are installed only from a `latest.json` signed with Oatcake's release key, only if the
  zip matches its checksum, and only if the new app carries the running app's code-signing
  identity (see [Updates](updates.md)).
- The calendar's private address is kept in `private.json` in Oatcake's data folder, which only
  your user account can read (mode 0600), and never in `config.json`.
- Files Oatcake rewrites (meeting Markdown, config, voiceprints, calendar, the calendar address)
  are written to a new temporary file and renamed into place, never through an existing file or
  link.
- `OatcakeRecorder.app` is what uses the microphone and system-audio permissions (macOS gives
  them to Oatcake, which it is inside), so it records only for Oatcake. As it starts it connects to a socket Oatcake gave it, checks from the system's own
  record of the process at the other end that it is Oatcake, signed with the recorder's own
  certificate, and asks whether Oatcake wants this recording; Oatcake says yes once, for a
  recording it has just started. Anything else that launches the recorder gets an error and no
  audio (`RecorderGate` in `Sources/RecorderContract`, `RecorderDoor` in the core). A development
  build signed ad-hoc skips the check: it has no certificate to check against, and no saved
  permissions to guard.
- Recorders before 0.5.0 had no such check, and macOS gives the permissions to Oatcake itself
  (the recorder is inside it), remembered against Oatcake's code-signing requirement: until
  0.5.0, "this identifier, this certificate", which every earlier release meets. So from 0.5.0 the
  requirement also says "0.5.0 or later", and the first time that version opens it withdraws the
  two permissions (`tccutil reset Microphone` and `AudioCapture`, for Oatcake and for the
  recorder's own identifier), to be given again to itself.
  That's why the first recording after updating asks once more. An earlier copy of Oatcake
  started by something else then no longer records quietly: macOS asks first, in Oatcake's name.
  It can't tell you which copy is asking, so if that question appears when you haven't just
  started a recording, choose Don't Allow. Either answer replaces what macOS remembers for
  Oatcake, so afterwards run `tccutil reset Microphone local.oatcake` in Terminal and allow it
  again at your next recording.
- Oatcake itself is signed as using the microphone (`Resources/Oatcake.entitlements`) although
  only the recorder opens it: macOS counts the recorder's use as Oatcake's, and under the hardened
  runtime it won't ask for the permission at all without that.
- The app, the recorder and llama.cpp's server are signed for the hardened runtime, so another
  program on your Mac can't load its own code into them to borrow the recorder's permissions.
- Once a meeting is saved, the recording's working folder in Oatcake's own data folder is
  deleted: the audio, the analysis with its voice fingerprints, and the working copy of your
  notes. With **Keep call audio after saving** on, the audio goes into the meeting's own folder as
  `audio.m4a` first, so it's in one place and goes to the Trash with the meeting. A meeting saved
  without checking who's who (After a call) keeps its analysis and voice clips there, but not the
  call's full tracks, until its voices are named, you choose Keep as is, or the meeting itself
  goes (to the Trash, or deleted in Finder; that's noticed at launch and after the next save).
- Recording one call at a time is enforced by the app. If Oatcake crashes mid-call, the recorder
  carries on for up to ten minutes; opening Oatcake again in that time picks the recording up,
  and after it the recorder finishes by itself. A recorder that has gone is noticed within a
  couple of seconds and what it captured is kept, so nothing is left recording unseen or stuck.
- Who can publish a release, and what the install line runs, are covered under [Releasing](releasing.md).
