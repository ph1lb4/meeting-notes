# Meeting Notes

Native macOS app that transcribes meetings on your Mac. Lives in the menu bar and the Dock.

- **Whisper** (WhisperKit, CoreML) for speech to text. German + English auto-detect.
- **Mic + call audio.** Call audio comes from a Core Audio process tap, so Zoom, Teams, Meet in the browser etc. all work.
- **Speakers.** Mic = "Me", call audio is split into Speaker 1, 2, … with Pyannote (SpeakerKit). In-person meetings (nothing on the call track) split the mic instead. Click a speaker chip to rename.
- **Live + final pass.** Text shows up live. After Stop, a cleaner pass with speaker labels runs on the recorded audio. Audio is deleted afterwards unless "Keep audio files" is on. If the app quits mid-meeting, the pass runs on the next launch.
- **Notes.** Type notes during the meeting. They get a timestamp and go to Claude.
- **Claude CLI** writes `summary.md` and `action-items.md` (auto after each meeting, or via the Summarize button). You can cancel a running summary.
- **Notion.** Copy button copies plain Markdown with headings, bullets and `- [ ]` to-dos. Pastes cleanly into Notion.

## Files

`~/Documents/Meeting Notes/<date> <title>/`

- `transcript.md` with your notes and the full transcript
- `summary.md`, `action-items.md`
- `meeting.json` (app state)
- `audio/` only if you keep audio

While recording, audio lives in `~/Library/Application Support/MeetingNotes/Recordings/<meeting id>/`, so it never lands in an iCloud synced folder. After the final transcript it is deleted, or moved to `audio/` if you keep audio.

Models live in `~/Library/Application Support/MeetingNotes/Models`. They are unloaded after 10 idle minutes and load again when needed.

## Privacy

- Transcription and speaker detection run on your Mac.
- The summary is written by Claude, so the transcript and your notes are sent to Anthropic when you summarize. Turn off auto summary in Settings to keep everything local.
- Call capture records all sound your Mac plays. Tell the others that you are recording.

## Build

```sh
brew install xcodegen
xcodegen generate
open MeetingNotes.xcodeproj
```

Requires macOS 15+, Apple silicon, and the `claude` CLI logged in for summaries.

On first recording macOS asks for **Microphone** and **System Audio Recording** access.

## Self test

Runs the full pipeline headless on two audio files:

```sh
"build/Build/Products/Debug/Meeting Notes.app/Contents/MacOS/Meeting Notes" --selftest mic.wav system.wav [--no-claude]
```
