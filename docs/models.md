# Speech and language models

## Speech models

FluidAudio is pinned to an exact version in `Package.swift`, with only its diarisation trait
(no text-to-speech, no prebuilt text-normalisation library). The models come from
FluidInference's Hugging Face repositories at fixed commits (`SpeechModels.pinnedRevisions`;
FluidAudio pins the diarisation models itself), so a change to a repository can't change what
Oatcake runs. Updating either is a deliberate change: bump it, then check transcripts and
speaker separation on a known meeting.

| Model | Used for | Licence |
| --- | --- | --- |
| Silero VAD | finding speech | MIT |
| Parakeet TDT 0.6B v2 | English transcription (default) | CC-BY-4.0 |
| Parakeet Ultra (post-trained v3) | 25 European languages | CC-BY-4.0 |
| pyannote community-1 (segmentation and its WeSpeaker-based embedding) | speaker turns and voice fingerprints | CC-BY-4.0 |

## Language model

Summaries, to-dos, name suggestions and Ask's answers come from one model, run on this Mac.

| Model | For | Download | Licence |
| --- | --- | --- | --- |
| Qwen3 8B (Q4_K_M) | Macs with 16 GB of memory or more; the default there | 5.0 GB | Apache-2.0 |
| Qwen3 4B (Q4_K_M) | Macs with 8 GB; fine on short calls, loses detail on long ones | 2.5 GB | Apache-2.0 |

- **Where it comes from.** Qwen's own GGUF files on Hugging Face, at a fixed revision, checked
  against their SHA-256 before use (`LocalModels` in `Sources/OatcakeCore/LocalModel.swift`). A
  download that's interrupted carries on from where it stopped. Settings › Summaries shows how far
  it has got, downloads it on request and removes it.
- **What runs it.** llama.cpp's server, inside Oatcake.app (MIT; the build is named in
  `Scripts/bundle.sh`). Oatcake starts it when there's something to write, on 127.0.0.1 at a port
  picked for the occasion, with a key made up each time so that a web page or another account on
  the Mac can't use it, and stops it after ten minutes with nothing to do, which gives its memory
  back.
- **How it's asked.** As Qwen advises for these models: its own sampling settings, never greedy
  decoding and room for a long reply. Whether it reasons before it replies is set for each task
  (Settings › Summaries): on to start with for summaries, name suggestions and Ask, where it
  measured better (decisions given to the right person, fewer invented names, answers that keep
  to the question), and off for to-dos, which lost detail with it. The summary and the to-dos are
  two requests about the same transcript, each with its task after the transcript; the to-dos,
  the name suggestions and Ask's first step come back as JSON the server holds to a schema, sent
  as it's written: the model fills in the fields in the schema's order, and a to-do's task has to
  come before its time (time first, it makes a to-do of every few minutes of the call). The
  summary's instructions are yours to change, and so is what counts as a to-do (Settings › Summaries).
- **How much it reads at once.** As little as the job needs, up to what this Mac's memory allows
  (the 8B takes about 5 GB plus 0.14 GB for every thousand tokens; an hour's call is around
  12,000). Qwen3 reads 32,768 tokens natively; a longer call stretches that with YaRN, by no more
  than it needs. A call too long for this Mac is summarised in parts, which are then joined.
- **A model of your own.** Any server with the same chat API on this Mac or your network (Ollama,
  LM Studio, your own llama.cpp). Oatcake only talks to a local address, and sends no key.

Changing the model or llama.cpp's build is a deliberate change, like the speech models: change the
revision and checksum together, then check summaries, to-dos and names on a known call.

## Accuracy


On two AMI meetings with four known speakers (ES2004a and IS1009a, 14–17 minutes each),
FluidAudio found all four people both times and gave 76–78% of speech to the right voice; the
Electron version's sherpa-onnx pipeline found five at 59% on the same audio and scoring.
Voiceprints from one meeting scored 0.85–0.95 against the same person in another (ES2004c) and
at most 0.34 against anyone else; a match needs 0.6 and a lead of 0.1 over the next person.
Expect to merge a split voice now and then, and to mark a voice "mixed" when two people sound
alike.
