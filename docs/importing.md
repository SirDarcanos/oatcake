# Importing from Granola and Quill

## Granola

Export your notes from Granola (it gives you a `.zip` holding a CSV), then in Oatcake open
Settings › Storage › Import from Granola › **Import…** and pick the `.zip` (or the CSV inside it). Each
note becomes a meeting folder with `summary.md`, `transcript.md`, `notes.md` (when Granola kept
your notes) and `meeting.json`, under a **Granola** folder in your Meetings folder. Notes that
share a title, like a weekly meeting, are grouped in a subfolder named after it; drag folders
wherever you like afterwards. Each meeting remembers its Granola note, so importing the same
export again (or a newer one) skips meetings that are already there, wherever you've moved them.

Granola's export has no speaker names or timestamps in its transcripts, so they show as plain
paragraphs, and it has no participants or end times. An imported meeting is marked Granola in the
meeting list and says it was imported. The import is in `Sources/OatcakeCore/Granola.swift`.

## Quill

Make a backup in Quill (it gives you a `QuillBackup-<date>.zip`), then in Oatcake open
Settings › Storage › Import from Quill › **Import…** and pick the `.zip`. Each meeting becomes a meeting
folder under a **Quill** folder, with meetings that share a title grouped in a subfolder as for
Granola. The folder holds:

- `transcript.md`, with times and speakers: your microphone is you, and voices on the call carry
  the names Quill matched to them, or "Voice 1", "Voice 2"…
- `summary.md`, made from Quill's notes on the meeting, if it wrote any.
- `audio.m4a`, the combined recording, whatever **Keep call audio after saving** is set to. Quill's separate
  mic and system tracks are left out.
- `meeting.json`, with the start and end times and the people named in the transcript.

Quill's search index (`vector_store.db`), contacts, threads and settings aren't imported, and
neither is a meeting with nothing in it (no words, notes or recording). Importing again skips
meetings already there. The import is in `Sources/OatcakeCore/Quill.swift`.
