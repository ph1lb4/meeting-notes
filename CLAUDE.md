# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Native macOS menu bar + Dock app (SwiftUI, macOS 15+, Apple silicon) that records meetings, transcribes them locally with WhisperKit, splits speakers with SpeakerKit (Pyannote), and summarizes via the local `claude` CLI.

## Commands

The Xcode project is generated. `project.yml` is the source of truth. Edit it, not `project.pbxproj`, then regenerate.

```sh
xcodegen generate                      # after adding/removing files or changing project.yml
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Debug -derivedDataPath build build
```

Unit tests (Swift Testing, `MeetingNotesTests/`) cover the pure logic: hallucination filter, Claude output parsing, echo removal, speaker relabeling, call detection, meeting JSON and Markdown export. The test bundle has no host app. It compiles `Models/`, `Claude/` and `Transcription/` directly, so code in those folders must not depend on `AppState` or views.

```sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -derivedDataPath build test
```

The headless self test runs the full pipeline (model load, live chunk, final pass + diarization, Claude summary) and exits 0/1:

```sh
"build/Build/Products/Debug/Meeting Notes.app/Contents/MacOS/Meeting Notes" --selftest mic.wav system.wav [--no-claude]
```

Signing is manual (`Apple Development`, team in `project.yml`), hardened runtime on. The only SPM dependency is `argmax-oss-swift` (WhisperKit + SpeakerKit), pinned to an exact version in `project.yml`.

## Architecture

**`AppState`** (`@MainActor @Observable`) is the single coordinator. Views read it from the environment. It owns the `TranscriptionEngine`, the active `RecordingSession`, and the meeting list. All WhisperKit work (model load, live chunks, final passes, unload) goes through `serialized { }`, a task chain that runs one engine job at a time. The engine is not safe for concurrent use, so keep new engine calls inside `serialized`.

**Model lifecycle:** `prepareModel()` bumps `modelGeneration`. A queued prepare job skips itself if it is no longer the latest request, and progress from old jobs is ignored. After 10 minutes with no recording, no final pass and no queued engine job, the engine is unloaded (`modelStatus = .idle`). `startRecording` and `finalize` (via `ensureModel()`) load it again.

**Live meters** (`elapsed`, `micLevel`, `systemLevel`) live in `AppState.meters` (`LiveMeters`, its own `@Observable`). Only small leaf views read them (`RecordingStatusView`, `ElapsedText`), so the detail view does not redraw on every tick. Do not read `meters` in large view bodies.

**Recording pipeline:**
1. `RecordingSession` starts two tracks: `MicCapture` (plain AVAudioEngine input tap on the device from `Prefs.micDeviceUID`, falling back to the system default when it is empty or not connected; voice processing was removed because it fails to initialize on some setups, echo is handled by `removeEcho`) and `SystemAudioCapture` (Core Audio process tap + private aggregate device, captures all call audio). System audio failure is non-fatal and becomes a warning.
2. Each `TrackRecorder` converts to 16 kHz mono (`AudioConverter16k`), writes `mic.caf` / `system.caf` into `~/Library/Application Support/MeetingNotes/Recordings/<meeting uuid>/` (never into the notes folder, which may sync to iCloud), pads silence to stay aligned with the wall clock, and runs an energy VAD that emits speech chunks.
3. Chunks go through a bounded `AsyncStream` (newest 12) to `AppState`, which transcribes them live and appends segments with speaker `"me"` (mic) or `"them"` (system). On stop the live task is cancelled: the chunk in flight finishes, queued chunks are dropped.
4. On stop, `TranscriptionEngine.finalize` re-transcribes the full files with word timestamps + VAD chunking and **replaces** the live segments. If the call track has >5 s of activity, the call track is diarized and mic lines that echo call audio are dropped (`removeEcho`). Otherwise (in-person) the mic track is diarized. Raw diarization ids are relabeled `s1`, `s2`, … by first appearance. Because the ids are assigned fresh on every pass, stored names for `s…` keys are cleared when a pass replaces the segments.
5. Then audio is deleted, or moved to the meeting folder's `audio/` with "Keep audio". If the pass failed, the audio stays in the recordings folder so "Transcribe Again" can retry. A pending title rename is applied, and `ClaudeRunner` auto-summarizes.

**Recovery:** a meeting keeps phase `.recording` / `.finalizing` on disk until its final pass is done. On launch, such a meeting gets the final pass again if its audio still exists (recordings folder or `audio/`), otherwise it is flipped to `.done`. Quitting while recording closes the audio files first (`prepareForTermination`). Recordings folders without a meeting are removed once per launch.

**Speaker keys** in `TranscriptSegment.speaker` are `me` (shown as "Mic"), `them` (shown as "Call"), `s1…sN`. Display names come from `Meeting.speakerNames` via `Meeting.displayName(for:)`. Rename by editing that map, never the segments. The only segment edit is "Same as…" in the speaker popover (`Meeting.mergeSpeaker`), which moves a wrongly split speaker's lines to another key; it is blocked while recording or finalizing.

**`HallucinationFilter`** cleans every Whisper segment (live and final) using `noSpeechProb` / `avgLogprob` and known junk phrases.

**Persistence** (`MeetingStore`, pure file helpers): one folder per meeting under `Prefs.notesFolder` (default `~/Documents/Meeting Notes/<date> <title>/`) with `meeting.json` (app state), `transcript.md`, `summary.md` (summary plus action items), and `audio/` (kept audio only). Meetings load off the main thread at launch (`reload()`), which never replaces meetings that are recording, finalizing or summarizing. New `Meeting` fields need a default in `Meeting.init(from:)` so old `meeting.json` files still decode.

**Save pipeline:** `AppState.update(_:)` changes the meeting in memory and marks it dirty. A debounced writer (1.5 s per meeting) snapshots the meeting and its folder path on the main actor and writes on `ioQueue`, a serial queue used for all meeting folder I/O. Folder renames, deletes and summary writes run with `ioQueue.sync`, so earlier writes finish first and no write can hit an old path or bring back a deleted folder. Call `flushSave(id)` when a write must be on disk right away (stop, end of final pass, summary, rename), and `flushAllSaves()` before changing the notes folder or quitting. Save errors show once per meeting via `errorMessage`. Renaming a meeting moves its folder (`syncFolderName`), so renames are deferred while recording or finalizing (`titleEdited` flag). The notes folder can only be changed while nothing is recording, finalizing or summarizing (`isBusy`).

**`ClaudeRunner`** shells out to `claude -p` with no tools, no session persistence and `--strict-mcp-config`, passing the prompt on stdin. It honors task cancellation and has a timeout. `AppState` keeps one summary task per meeting (`cancelSummary`). Each summary write bumps `Meeting.summaryRevision`, which the summary views use to reload the files. Output must contain `<<<TITLE>>>`, `<<<SUMMARY>>>`, `<<<ACTION_ITEMS>>>` markers, which `parse` splits. The CLI path comes from Settings, known install locations, a login shell `command -v claude`, and as a last resort the private copy inside the Claude desktop app (`~/Library/Application Support/Claude/claude-code/<version>/<hash>/claude.app`, layout can change any time). Output is plain Markdown meant to paste into Notion (no HTML/tables/emojis).

**Summary engines:** `Prefs.summaryEngine` is `auto` (Claude, else Apple Intelligence), `claude` or `apple`. `AppState.refreshSummaryEngines()` detects the CLI (+ version) and Apple Intelligence status; `availableEngine` picks the engine. `AppleSummarizer` (FoundationModels, macOS 26+, guarded with `#if canImport` / `#available`) uses guided generation and summarizes long transcripts in ~5000 character parts first, because the on-device context is ~4k tokens. It renders the same Markdown layout as Claude. With no engine, the auto summary after a final pass is skipped silently and the summary tab shows `NoSummaryEngineView`. Test the on-device path with `--apple-summary-test` or `--selftest … --apple`.

**Settings** live in `UserDefaults` via the `Prefs` enum so non-UI code can read them. Add new keys to `Prefs.Key` and `registerDefaults()`. Whisper models download to `~/Library/Application Support/MeetingNotes/Models`, with an offline fallback to an earlier download.

**Permissions:** `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` are set in `project.yml` (`info.properties`), not directly in `Info.plist`.
