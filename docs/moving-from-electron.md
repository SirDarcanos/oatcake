# Moving from the Electron version (0.3 and earlier)

0.4.0 is the same app rebuilt in Swift, with the same bundle ID, certificate and update feed, so
0.3.0 updates to it (or to any later version) in place. The first launch, once:

- moves the calendar address from `secrets.json` (Electron's encrypted store) into
  `private.json`, then deletes `secrets.json`;
- drops the keys for the Anthropic API and for an OpenAI-compatible service, if you'd saved
  either: summaries are written by a model on your Mac now. Settings that named Claude become the
  model recommended for your Mac; a model server on your own Mac or network carries over;
- deletes the old sherpa-onnx models (about 700 MB) and Electron's `Chromium` cache folder;
- keeps everything else as it was: `config.json`, the Meetings folder, recordings waiting for
  review, and `calendar.json`.

Voice fingerprints come from a different model now, so `voiceprints.json` keeps the names it
knows (they're still offered in review) but not their old fingerprints: each person is
recognised again after one saved call. A recording analysed by the old version but not yet
saved can still be reviewed and saved; its fingerprints aren't kept. Avatar colours start
afresh.
