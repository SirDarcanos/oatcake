# Settings

Settings (⌘,) is its own window, with a pane for each part of Oatcake; changes apply as you make
them. They're stored in `~/Library/Application Support/Oatcake/config.json`, apart from the
calendar's address (see [Calendar](#calendar)). If `config.json` can't be read, Oatcake starts on
its defaults, says so when it opens, and keeps the file beside it as `config.unreadable.json`. A
switch that works by notification says so when notifications are turned off for Oatcake in System
Settings, with **Open Notification Settings**.

## General

- **Your name:** labels your microphone track in every transcript, and is who "Mine" means on the
  To-dos page.
- **Microphone:** "Same as Mac" follows System Settings › Sound; a chosen mic is used until it's
  unplugged, then the Mac's input until it's back. It can also be changed on the record screen
  and during the call (see [Record](how-it-works.md#1-record)).
- **Live transcript** (on to start with): shows what's being said beside your notes during the
  call (see [Live transcript](how-it-works.md#live-transcript)).
- **After a call:** wait for you to check who's who (the default), or save each call once it's
  processed, with a summary or with the transcript only (see
  [Saving without Who's who](how-it-works.md#saving-without-whos-who)).
- **Offer to record when a call starts** and **Stop recording when the call ends** (both on to
  start with): see [Calls are noticed](how-it-works.md#calls-are-noticed).
- **Collect to-dos** (on to start with). Turned off, no to-dos are asked for when a summary is
  written, and the To-dos page, the sidebar's counts, each meeting's checklist, Regenerate to-dos
  and the to-do settings are hidden; Copy, Share, search and Ask leave to-dos out. Each meeting's
  `todo.md` is left as it is, so turning it back on brings them back. The summary still doesn't
  list action items (Summary instructions say so), so with this off they aren't kept anywhere
  unless you change those instructions.

## Calendar

- **Private iCal address:** **Add…** opens a field to paste your calendar's private iCal address
  into (Google Calendar › Settings › your calendar › Integrate calendar › "Secret address in iCal
  format"); it's saved as you paste, and **Done** or Return closes the field. It's kept in
  `private.json` in Oatcake's data folder, which only your user account can read, not in
  `config.json`, and Settings shows only that one is saved and which server it's on, with how the
  last fetch went. **Replace…** pastes another in its place; **Remove…** deletes it. (0.4.0 to 0.5.2 kept it in your login Keychain, which asked for your login password
  after every update; the first launch of a later version moves it, asking that one last time.)
  Without one, Upcoming is hidden.

  Oatcake fetches it once an hour, or when you press ↻ next to Upcoming (⌘R), and keeps events
  from yesterday to two weeks ahead in `calendar.json`. Upcoming in the sidebar lists up to six
  events from the rest of today and tomorrow, leaving out all-day events and ones you declined. A
  failed fetch keeps the last events and turns ↻ red; hover it for the reason.

  Clicking an event opens New recording for it, named after it, in the folder with the same name
  or path ("John & Jane 1:1" finds "John & Jane 1-1", "Product – Weekly sync" finds "Product ›
  Weekly sync"), or offering a new folder for a recurring event with none. **Join the call** opens
  its Meet, Zoom or Teams link (only links on those services' own domains count, so a look-alike
  address is never opened).
- **Remind me before calls** (on to start with): 5 minutes before each timed event, a
  notification with **Open call and start note taking**. The button opens the call link when the
  event has one, starts recording it (in the folder named like the event; a new folder for a
  recurring event without one, ":" and "/" becoming "-"), and brings Oatcake forward on the live
  notes. Clicking the notification itself opens New recording for the event. macOS asks once
  whether Oatcake may send notifications; the packaged app asks for Alerts, so reminders stay up
  until dealt with.
- **Show my next call in the menu bar** (on to start with, with a calendar connected): Oatcake's
  oatcake with the time until it starts, and what's coming up in its menu (see
  [The menu bar](how-it-works.md#the-menu-bar)). With this on, closing Oatcake's window leaves it
  running in the menu bar, so reminders and call notices keep working.
- **Events that aren't calls:** events whose titles start with one of these names, as whole words
  ("Focus time", "Out of office", "Working location" and "Task" to begin with; "Task" doesn't leave
  out "Taskforce sync"), or that have "Oatcake ignore" anywhere in the title, are left out of
  Upcoming, the menu bar and reminders. Separate them with commas; capitals don't matter. iCal
  doesn't say which events are Google's focus-time or out-of-office blocks, so a block renamed to
  something else still appears, and a call whose title starts with one of those names doesn't.
- **Ignored events:** a call you can't rename (someone else's recurring meeting) can be ignored on
  its own: right-click it in Upcoming for **Ignore This Event**, or for a recurring one **Ignore
  This One** or **Ignore This and Following Events**. That's kept in `config.json`, nothing changes
  in your calendar, and **Stop Ignoring** here brings one back (the list shows once there are
  some). An occurrence its organiser moves shows again (its ID includes its start), and so does the
  rest of a series changed with Google's "this and following events" (that gives it a new UID).

## People

The voices Oatcake recognises. **Rename…** one ("John" to "John Smith") to change the name it
suggests from now on. **Merge Into** (once there are two or more) makes two people one, under the
name you pick from its menu: both sets of fingerprints are kept, up to the 10 newest, and it asks
first; renaming to a name that's already there does the same. **Forget…** stops it recognising
them. Meetings already saved keep the names they were saved with (to change
one meeting's, use [Rename Speakers](how-it-works.md#rename-speakers)).

Click someone's avatar to choose their colour from the palette's twelve: it's theirs everywhere,
in avatars and in names in transcripts. Oatcake otherwise gives each first name a colour the first
time it sees it, so a colour you choose is kept for the full name, and two people called Jane can
have different ones. **Use the colour Oatcake gave them** goes back to that. Renaming someone takes
their chosen colour with them, and so does merging them into someone who hasn't one.

## Models

- **Speech to text:** Parakeet English, or Parakeet for 25 European languages
  (`SpeechModels.asr`); FluidAudio runs other models too. See [Speech models](models.md#speech-models).
- **Language model:** what writes summaries, to-dos and drafts for sharing, suggests names and answers questions.
  Qwen3 8B or Qwen3 4B, which Oatcake downloads and runs on this Mac (the one that suits its memory
  is chosen to start with, and marked "recommended for this Mac"; one this Mac has too little
  memory for says so), or a model server of your own: Ollama, LM Studio or another with the same
  chat API (`http://localhost:11434/v1` for Ollama). Its address has to be this Mac, a machine on
  your network or a private IP address, and no key is sent to it. **Download Now** fetches the
  chosen model straight away rather than at your first call, **Stop** stops a download, **Remove…**
  deletes it (or **Remove Partial Download**), and **Test** asks it for one word. See
  [Language model](models.md#language-model).

(Earlier versions had speech to text in a pane of its own, Transcription.)

## Summaries

One section for each thing the model writes, each with its instructions and its reasoning switch
side by side. Instructions show as Oatcake's own or yours; **Edit…** opens them below (saved as
you type), and **Restore Default…** there brings Oatcake's own back. **Reasoning** is whether the
model thinks a task through before it replies: slower, and not always better. Each switch says
how it did in Oatcake's tests. They're for Oatcake's own models: with a server of yours they're
shown but can't be changed, as it decides for itself.

- **Jargon:** names, products and acronyms, separated by commas. The model is told to spell them
  as written, in summaries, to-dos, drafts, name suggestions and Ask's answers. Transcripts keep
  what the speech model heard.
- **Summary:** what the model is told to write once it has read the transcript. Change the
  headings, the level of detail or the language to suit you. To-dos are collected separately and
  aren't affected. Reasoning starts on: decisions went to the right person more reliably with it.
- **Summary templates:** other summary instructions, each with a name, for the meetings that need a
  different summary (a one-to-one you lead, one with your own lead, a team meeting). **Add
  Template** starts one as a copy of the summary instructions; change its name and instructions in
  place, or **Delete…** it. Pick one for a meeting from **Regenerate › Regenerate summary** (see
  [Regenerate and summary templates](how-it-works.md#regenerate-and-summary-templates)); the
  meeting keeps it (in its `meeting.json`) and every other meeting keeps the summary instructions.
  A meeting keeps its template by name: once that template is renamed or deleted, the meeting is
  back on the summary instructions, until a template is given that name again. A template with no
  instructions means the summary instructions. The summary starts at the model's
  first `## ` heading: anything written before it is left out.
- **To-dos** (while to-dos are collected): what the model is told counts as a to-do. Oatcake's
  own keep it to what somebody said they'd do after the call, and leave out what was only
  discussed, what was asked and not taken on, what was done during the call, and small talk. Make
  it stricter or looser, or keep it to your own action items. The shape of each to-do (task,
  owner, due date, time) isn't part of it. Reasoning starts off: to-dos lost detail with it.
- **Draft for sharing:** what the model is told when it writes a meeting's
  [draft for sharing](how-it-works.md#draft-for-sharing) from its summary and to-dos. Oatcake's
  own ask for an update for people who weren't there: decisions and next steps first, short
  bullet points, nothing the notes don't say. Reasoning starts on, as for summaries (not measured
  for drafts).
- **Reasoning for name suggestions and Ask:** both start on: names were made up less often, and
  answers kept to the question.

## Storage

- **Meetings folder:** where meetings are saved; **Choose…** picks another. Choosing another folder
  doesn't move anything: meetings already in the old one stay where they are.
- **Keep call audio after saving** (off to start with): audio is deleted once a meeting is saved.
  When on, the call's audio (both sides, mixed) is saved in the meeting's folder as `audio.m4a`.
- **Import from Granola** and **Import from Quill:** **Import…** picks an export (see
  [Importing](importing.md)).

## Updates

- **Check Now**, and what's new in a release that's waiting, with **Install and Relaunch** (or the
  install line to copy, for a copy that can't update itself).
- **Check for updates automatically** (on to start with): once a day. Nothing is installed until
  you choose to. See [Updates](updates.md).
