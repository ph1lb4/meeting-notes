import AppKit
import Foundation
import Observation

/// Live recording meters. Separate from AppState so only the small status views redraw on each tick.
@MainActor
@Observable
final class LiveMeters {
    private(set) var elapsed: Double = 0
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// Publishes only visible changes, so a quiet room causes no view updates.
    func set(elapsed: Double, mic: Float, system: Float) {
        let seconds = elapsed.rounded(.down)
        if seconds != self.elapsed { self.elapsed = seconds }
        if abs(mic - micLevel) > 0.0005 { micLevel = mic }
        if abs(system - systemLevel) > 0.0005 { systemLevel = system }
    }

    func reset() {
        if elapsed != 0 { elapsed = 0 }
        if micLevel != 0 { micLevel = 0 }
        if systemLevel != 0 { systemLevel = 0 }
    }
}

@MainActor
@Observable
final class AppState {
    enum ModelStatus: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    var meetings: [Meeting] = []
    var selectedID: UUID?
    var recordingID: UUID?
    var modelStatus: ModelStatus = .idle
    var finalizing: [UUID: String] = [:]
    var summarizing: Set<UUID> = []
    /// Engine of each running summary, for the progress text.
    var summaryEngines: [UUID: SummaryEngine] = [:]
    /// Claude CLI found by the last check, nil if none.
    var claudeCLI: String?
    var appleIntelligence: AppleSummarizer.Status = .unsupportedOS
    var engineChoice: SummaryEngineChoice = .auto
    /// `claude --version` of the found CLI.
    var claudeVersion: String?
    /// False until the first engine check is done, so the UI does not flash "not found".
    var enginesChecked = false
    var errorMessage: String?
    var warningMessage: String?

    /// Elapsed time and levels of the running recording. Read these only in small leaf views.
    @ObservationIgnored let meters = LiveMeters()

    @ObservationIgnored private let engine = TranscriptionEngine()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var liveContinuation: AsyncStream<LiveChunk>.Continuation?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var meterTimer: Timer?
    /// True between the Record click and the start of the session (permission prompt).
    @ObservationIgnored private var starting = false

    // Engine
    /// Serializes all WhisperKit work (model load, live chunks, final passes, unload).
    @ObservationIgnored private var engineQueue: Task<Void, Never>?
    /// Engine jobs queued or running.
    @ObservationIgnored private var engineJobs = 0
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    /// Bumped on every model request. Older prepare jobs skip themselves.
    @ObservationIgnored private var modelGeneration = 0
    /// Generation of the prepare job that is running right now.
    @ObservationIgnored private var activePrepare: Int?
    /// Prepare jobs queued or running.
    @ObservationIgnored private var pendingPrepares = 0
    @ObservationIgnored private var unloading = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    private static let idleUnloadDelay: Double = 600

    // Saving
    /// All meeting folder I/O runs here, in order. Paths are resolved on the main actor when a job is queued.
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "com.soonup.meetingnotes.store", qos: .utility)
    /// Meetings changed in memory but not yet written.
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveFailed: Set<UUID> = []
    private static let saveDelay: Double = 1.5

    @ObservationIgnored private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var cleanedRecordings = false

    private struct LiveChunk {
        var source: AudioSource
        var samples: [Float]
        var start: Double
    }

    var isRecording: Bool { recordingID != nil }

    /// What would write the next summary, based on the engine setting and what is installed.
    var availableEngine: SummaryEngine? {
        let claude = claudeCLI != nil
        let apple = appleIntelligence == .available
        switch engineChoice {
        case .auto: return claude ? .claude : (apple ? .apple : nil)
        case .claude: return claude ? .claude : nil
        case .apple: return apple ? .apple : nil
        }
    }

    /// True while a meeting is recording, finalizing or being summarized.
    var isBusy: Bool { recordingID != nil || !finalizing.isEmpty || !summarizing.isEmpty }

    init() {
        Prefs.registerDefaults()
        prepareModel()
        reload()
        Task { await refreshSummaryEngines() }
    }

    // MARK: - Loading

    /// Reads the notes folder off the main thread and publishes the list when done.
    /// Meetings that are recording, finalizing or summarizing are kept as they are in memory.
    func reload() {
        flushAllSaves()
        loadGeneration += 1
        let generation = loadGeneration
        let root = Prefs.notesFolder
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { MeetingStore.loadAll(in: root) }.value
            guard generation == loadGeneration else { return }
            apply(loaded)
        }
    }

    /// Switches the notes folder. Ignored while a meeting is busy.
    func setNotesFolder(_ url: URL) {
        guard !isBusy else { return }
        flushAllSaves() // pending changes belong to the old folder
        Prefs.defaults.set(url.path, forKey: Prefs.Key.notesFolder)
        reload()
    }

    private func apply(_ loaded: [Meeting]?) {
        var active = Set(finalizing.keys).union(summarizing)
        if let recordingID { active.insert(recordingID) }
        let kept = meetings.filter { active.contains($0.id) }
        // Drop pending saves of meetings that leave the list, so nothing is written for them later.
        for id in dirty where !active.contains(id) {
            saveTasks[id]?.cancel()
            saveTasks[id] = nil
            dirty.remove(id)
        }
        let fresh = (loaded ?? []).filter { !active.contains($0.id) }
        meetings = (kept + fresh).sorted { $0.createdAt > $1.createdAt }
        if let selectedID, meeting(selectedID) == nil { self.selectedID = nil }

        // Recover meetings interrupted by a crash or quit.
        for m in fresh where m.phase != .done {
            if let folder = MeetingStore.audioSource(for: m) {
                // Audio survived: finish the transcript now. This also removes the audio per the setting.
                startFinalPass(m.id, input: Self.finalInput(in: folder))
            } else {
                var fixed = m
                fixed.phase = .done
                update(fixed)
            }
        }

        // Once per launch, and only if the notes folder was readable, remove recordings without a meeting.
        if loaded != nil, !cleanedRecordings {
            cleanedRecordings = true
            let orphans = MeetingStore.orphanRecordings(keeping: Set(meetings.map(\.id)))
            if !orphans.isEmpty { ioQueue.async { MeetingStore.remove(orphans) } }
        }
    }

    // MARK: - Model

    private var modelLoaded: Bool { !unloading && engine.loadedModel == Prefs.model }

    func prepareModel() {
        let model = Prefs.model
        modelGeneration += 1
        let generation = modelGeneration
        if pendingPrepares == 0, modelLoaded { modelStatus = .ready; return }
        modelStatus = .downloading(0)
        pendingPrepares += 1
        modelTask = Task {
            defer { pendingPrepares -= 1 }
            do {
                try await serialized {
                    // A newer request came in while this one was queued.
                    guard generation == self.modelGeneration else { return }
                    self.activePrepare = generation
                    defer { if self.activePrepare == generation { self.activePrepare = nil } }
                    try await self.engine.prepare(model: model) { fraction in
                        Task { @MainActor in
                            // Ignore progress from an old request or one that arrives after the job ended.
                            guard self.activePrepare == generation, generation == self.modelGeneration else { return }
                            self.modelStatus = fraction >= 1 ? .loading : .downloading(fraction)
                        }
                    }
                }
                if generation == modelGeneration { modelStatus = .ready }
            } catch {
                if generation == modelGeneration { modelStatus = .failed(error.localizedDescription) }
            }
        }
    }

    /// Loads the model again if it was unloaded or failed, then waits for it.
    private func ensureModel() async {
        if pendingPrepares == 0, !modelLoaded { prepareModel() }
        await modelTask?.value
    }

    /// Runs engine work one job at a time.
    private func serialized<T>(_ work: @escaping () async throws -> T) async throws -> T {
        idleTask?.cancel()
        idleTask = nil
        engineJobs += 1
        let previous = engineQueue
        let task = Task { () async throws -> T in
            await previous?.value
            defer {
                self.engineJobs -= 1
                self.scheduleIdleUnload()
            }
            return try await work()
        }
        engineQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    private var canUnload: Bool {
        engineJobs == 0 && recordingID == nil && !starting && finalizing.isEmpty && engine.loadedModel != nil
    }

    /// Frees Whisper and Pyannote after a while without engine work. They load again on demand.
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = nil
        guard canUnload else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadDelay))
            guard !Task.isCancelled, let self, self.canUnload else { return }
            self.idleTask = nil
            _ = try? await self.serialized {
                // Check again: this job is the only one allowed in the queue.
                guard self.engineJobs == 1, self.recordingID == nil, !self.starting, self.finalizing.isEmpty else { return }
                self.unloading = true
                await self.engine.unloadAll()
                self.unloading = false
                if self.pendingPrepares == 0 { self.modelStatus = .idle }
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !starting else { return }
        starting = true
        Task {
            defer {
                starting = false
                if !isRecording { scheduleIdleUnload() }
            }
            guard await MicCapture.requestPermission() else {
                errorMessage = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        if pendingPrepares == 0, !modelLoaded { prepareModel() }

        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        let title = "Meeting \(f.string(from: now))"
        var meeting = Meeting(title: title, createdAt: now, folderName: MeetingStore.makeFolderName(date: now, title: "Meeting"))
        meeting.phase = .recording

        // Audio goes to Application Support, not into the notes folder.
        let recordingFolder = MeetingStore.recordingFolder(for: meeting.id)
        let session = RecordingSession(audioFolder: recordingFolder)
        // Bounded, so memory stays flat while the model is still loading or lags behind.
        let (stream, continuation) = AsyncStream<LiveChunk>.makeStream(bufferingPolicy: .bufferingNewest(12))
        do {
            try session.start(captureSystemAudio: Prefs.captureSystemAudio) { source, samples, start in
                continuation.yield(LiveChunk(source: source, samples: samples, start: start))
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            ioQueue.async { MeetingStore.remove([recordingFolder]) }
            return
        }
        if let err = session.systemAudioError {
            warningMessage = "Call audio is not captured (\(err)). Only your microphone is recorded."
        }

        self.session = session
        liveContinuation = continuation
        meetings.insert(meeting, at: 0)
        selectedID = meeting.id
        recordingID = meeting.id
        meters.reset()
        update(meeting)
        flushSave(meeting.id)

        let meetingID = meeting.id
        liveTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.modelTask?.value
                // Stop cancels this task: chunks still waiting are dropped, the final pass covers them.
                if Task.isCancelled { return }
                let parts = (try? await self.serialized { await self.engine.transcribeChunk(chunk.samples) }) ?? []
                if Task.isCancelled { return }
                guard !parts.isEmpty, var m = self.meeting(meetingID) else { continue }
                for p in parts {
                    m.segments.append(TranscriptSegment(start: chunk.start + p.start, end: chunk.start + p.end,
                                                        speaker: chunk.source == .mic ? "me" : "them", text: p.text))
                }
                m.segments.sort { $0.start < $1.start }
                self.update(m)
            }
        }

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            // Timers on the main run loop fire on the main thread.
            MainActor.assumeIsolated {
                guard let self, let s = self.session else { return }
                self.meters.set(elapsed: s.duration, mic: s.micLevel, system: s.systemLevel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopRecording() {
        guard let session, let id = recordingID else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        session.stop()
        liveContinuation?.finish()
        liveContinuation = nil
        liveTask?.cancel()
        liveTask = nil
        self.session = nil
        recordingID = nil
        meters.reset()

        if session.writeFailed {
            warningMessage = "Some audio could not be written to disk, so the final transcript may have gaps. Check free disk space."
        }
        guard var meeting = meeting(id) else {
            // Should not happen. Do not leave audio behind.
            let folder = session.audioFolder
            ioQueue.async { MeetingStore.remove([folder]) }
            scheduleIdleUnload()
            return
        }
        meeting.duration = session.duration
        meeting.phase = .finalizing
        update(meeting)
        flushSave(id)

        startFinalPass(id, input: .init(micURL: session.micURL,
                                        systemURL: session.systemTrack == nil ? nil : session.systemURL))
    }

    // MARK: - Final pass

    private static func finalInput(in folder: URL) -> TranscriptionEngine.FinalInput {
        .init(micURL: folder.appendingPathComponent(MeetingStore.micFileName),
              systemURL: folder.appendingPathComponent(MeetingStore.systemFileName))
    }

    private func startFinalPass(_ id: UUID, input: TranscriptionEngine.FinalInput) {
        guard finalizing[id] == nil else { return }
        finalizing[id] = "Waiting for model…"
        if var m = meeting(id), m.phase != .finalizing {
            // Marks the meeting so an interrupted pass is picked up again on the next launch.
            m.phase = .finalizing
            update(m)
        }
        Task { await finalize(id, input: input) }
    }

    private func finalize(_ id: UUID, input: TranscriptionEngine.FinalInput) async {
        await ensureModel()
        var failed = false
        do {
            let segments = try await serialized {
                try await self.engine.finalize(input) { status in
                    Task { @MainActor in
                        if self.finalizing[id] != nil { self.finalizing[id] = status }
                    }
                }
            }
            if var m = meeting(id), !segments.isEmpty {
                m.segments = segments
                // s1, s2, ... are assigned fresh on every pass, so old names could land on the wrong person.
                m.speakerNames = m.speakerNames.filter { !Meeting.isDiarizedKey($0.key) }
                if m.duration == 0, let last = segments.last { m.duration = last.end }
                update(m)
            }
        } catch {
            failed = true
            if meeting(id) != nil {
                errorMessage = "Final transcription failed, keeping the live transcript. The audio is kept so you can try again from the More menu. \(error.localizedDescription)"
            }
        }
        finalizing[id] = nil
        defer { scheduleIdleUnload() }

        guard var m = meeting(id) else { return } // deleted meanwhile
        m.phase = .done
        update(m)

        if !failed {
            let recording = MeetingStore.recordingFolder(for: id)
            let kept = MeetingStore.audioFolder(for: m)
            if Prefs.keepAudio {
                do {
                    try await io { try MeetingStore.keepAudio(from: recording, to: kept) }
                } catch {
                    reportSaveFailure(id, folder: kept)
                }
            } else {
                try? await io { MeetingStore.deleteAudio(recording: recording, kept: kept) }
            }
        }

        guard let current = meeting(id) else { return }
        if current.titleEdited, recordingID != id, finalizing[id] == nil {
            // Title was changed while recording or finalizing; move the folder now.
            syncFolderName(id)
        } else {
            flushSave(id)
        }
        if Prefs.autoSummarize && !current.segments.isEmpty { summarize(id, auto: true) }
    }

    func hasAudio(_ meeting: Meeting) -> Bool {
        MeetingStore.audioSource(for: meeting) != nil
    }

    /// Re-runs the final pass on audio that is still around.
    func retranscribe(_ id: UUID) {
        guard let m = meeting(id), recordingID != id, finalizing[id] == nil,
              let folder = MeetingStore.audioSource(for: m) else { return }
        startFinalPass(id, input: Self.finalInput(in: folder))
    }

    // MARK: - Summary

    /// Looks for the Claude CLI (off the main thread) and checks Apple Intelligence.
    func refreshSummaryEngines() async {
        let (path, version) = await Task.detached(priority: .utility) { () -> (String?, String?) in
            let path = ClaudeRunner.findClaude()
            return (path, path.flatMap(ClaudeRunner.version(at:)))
        }.value
        claudeCLI = path
        claudeVersion = version
        appleIntelligence = AppleSummarizer.status
        engineChoice = Prefs.summaryEngine
        enginesChecked = true
    }

    var noEngineText: String {
        switch engineChoice {
        case .auto: return "No summary engine found. Install Claude Code or turn on Apple Intelligence. Settings shows how."
        case .claude: return "Claude Code was not found. Install it or pick another engine in Settings."
        case .apple: return "Apple Intelligence is not available. \(appleIntelligence.message)"
        }
    }

    /// `auto` is the run after a final pass. Without any engine it does nothing; the summary tab shows how to set one up.
    func summarize(_ id: UUID, auto: Bool = false) {
        guard let m = meeting(id), !summarizing.contains(id) else { return }
        summarizing.insert(id)
        summaryTasks[id] = Task {
            defer {
                summarizing.remove(id)
                summaryEngines[id] = nil
                summaryTasks[id] = nil
            }
            await refreshSummaryEngines()
            guard !Task.isCancelled else { return }
            guard let engine = availableEngine else {
                if !auto { errorMessage = noEngineText }
                return
            }
            summaryEngines[id] = engine
            do {
                let out: ClaudeRunner.Output
                switch engine {
                case .claude:
                    out = try await ClaudeRunner.run(for: m, workingDirectory: MeetingStore.folder(for: m), claudePath: claudeCLI)
                case .apple:
                    out = try await AppleSummarizer.run(for: m)
                }
                try Task.checkCancellation()
                guard let before = meeting(id) else { return }
                if let title = out.title, !before.titleEdited, recordingID != id, finalizing[id] == nil, title != before.title {
                    var renamed = before
                    renamed.title = title
                    update(renamed)
                    syncFolderName(id)
                }
                guard var current = meeting(id) else { return }
                let dir = MeetingStore.folder(for: current)
                // Action items live in the summary page, so they go into summary.md.
                let summary = "# \(current.title)\n\n\(MarkdownExporter.header(for: current))\n\n" + out.summary
                    + "\n\n## Action items\n\n" + out.actionItems + "\n"
                do {
                    try ioQueue.sync {
                        try MeetingStore.write(summary, to: dir.appendingPathComponent(MeetingStore.summaryName))
                    }
                } catch {
                    errorMessage = Self.saveFailureText(dir)
                    return
                }
                current.hasSummary = true
                current.summaryRevision += 1
                update(current)
                flushSave(id)
            } catch is CancellationError {
                // Cancelled by the user or the meeting was deleted.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelSummary(_ id: UUID) {
        summaryTasks[id]?.cancel()
    }

    // MARK: - Saving

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// Updates the meeting in memory right away and saves it a moment later, off the main thread.
    /// Meetings that are no longer in the list are ignored, so a late update cannot bring back a deleted folder.
    func update(_ meeting: Meeting) {
        guard let i = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[i] = meeting
        scheduleSave(meeting.id)
    }

    private func scheduleSave(_ id: UUID) {
        dirty.insert(id)
        guard saveTasks[id] == nil else { return } // one write per window, later changes ride along
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.saveDelay))
            guard !Task.isCancelled, let self else { return }
            self.saveTasks[id] = nil
            self.writeSnapshot(id, wait: false)
        }
    }

    /// Queues the current state of a dirty meeting for writing. The snapshot and its folder are taken here,
    /// on the main actor, so they always match. Renames and deletes go through the same queue with `sync`,
    /// which means every write queued before them has finished and none can follow with an old path.
    private func writeSnapshot(_ id: UUID, wait: Bool) {
        guard dirty.remove(id) != nil, let m = meeting(id) else { return }
        let dir = MeetingStore.folder(for: m)
        if wait {
            do {
                try ioQueue.sync { try MeetingStore.save(m, to: dir) }
            } catch {
                reportSaveFailure(id, folder: dir)
            }
        } else {
            ioQueue.async { [weak self] in
                do {
                    try MeetingStore.save(m, to: dir)
                } catch {
                    Task { @MainActor [weak self] in self?.reportSaveFailure(id, folder: dir) }
                }
            }
        }
    }

    /// Writes pending changes of one meeting now and waits for the write.
    private func flushSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        writeSnapshot(id, wait: true)
    }

    /// Writes all pending changes and waits until the store queue is empty.
    func flushAllSaves() {
        for id in Array(dirty) { flushSave(id) }
        ioQueue.sync {}
    }

    /// Runs slow file work on the store queue without blocking the main thread.
    private func io<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func saveFailureText(_ folder: URL) -> String {
        "Could not save the meeting to \(folder.path). Check disk space and folder permissions."
    }

    /// Shows a save error once per meeting, not on every write.
    private func reportSaveFailure(_ id: UUID, folder: URL) {
        NSLog("Saving meeting failed: \(folder.path)")
        guard meeting(id) != nil, saveFailed.insert(id).inserted else { return }
        errorMessage = Self.saveFailureText(folder)
    }

    /// Renames the meeting folder to match the current title, then saves.
    private func syncFolderName(_ id: UUID) {
        guard var m = meeting(id) else { return }
        let newName = MeetingStore.makeFolderName(date: m.createdAt, title: m.title, current: m.folderName)
        if newName != m.folderName {
            let from = MeetingStore.folder(for: m)
            let to = Prefs.notesFolder.appendingPathComponent(newName, isDirectory: true)
            do {
                // sync waits for queued writes to the old path before the folder moves.
                try ioQueue.sync { try MeetingStore.move(from, to: to) }
                m.folderName = newName
            } catch {
                reportSaveFailure(id, folder: from)
            }
        }
        update(m)
        flushSave(id)
    }

    /// Called when the app quits. Closes a running recording and writes everything that is pending.
    /// The meeting keeps its unfinished phase, so the next launch runs the final pass on the audio.
    func prepareForTermination() {
        if let session, let id = recordingID {
            meterTimer?.invalidate()
            meterTimer = nil
            liveTask?.cancel()
            session.stop()
            self.session = nil
            if var m = meeting(id) {
                m.duration = session.duration
                update(m)
            }
        }
        flushAllSaves()
    }

    // MARK: - Editing

    func addNote(_ text: String, to id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var m = meeting(id) else { return }
        let time = (recordingID == id ? session?.duration : nil) ?? m.duration
        m.notes.append(MeetingNote(time: time, text: trimmed))
        update(m)
    }

    func deleteNote(_ noteID: UUID, from id: UUID) {
        guard var m = meeting(id) else { return }
        m.notes.removeAll { $0.id == noteID }
        update(m)
    }

    func renameSpeaker(_ key: String, to name: String, in id: UUID) {
        guard var m = meeting(id) else { return }
        m.speakerNames[key] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(m)
    }

    /// Not while recording or finalizing: live chunks keep adding lines and the final pass replaces them.
    func mergeSpeaker(_ key: String, into target: String, in id: UUID) {
        guard recordingID != id, finalizing[id] == nil, var m = meeting(id) else { return }
        m.mergeSpeaker(key, into: target)
        update(m)
    }

    func setTitle(_ title: String, for id: UUID) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var m = meeting(id), !t.isEmpty, t != m.title else { return }
        m.titleEdited = true
        m.title = t
        update(m)
        // While recording or finalizing the folder move waits for the end of the final pass.
        if recordingID != id, finalizing[id] == nil { syncFolderName(id) }
    }

    func delete(_ id: UUID) {
        guard let m = meeting(id), recordingID != id else { return }
        summaryTasks[id]?.cancel()
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        dirty.remove(id)
        meetings.removeAll { $0.id == id }
        let folder = MeetingStore.folder(for: m)
        let recording = MeetingStore.recordingFolder(for: id)
        // sync: writes queued earlier finish first, and nothing is queued for this meeting afterwards.
        ioQueue.sync { MeetingStore.delete(folder: folder, recording: recording) }
        if selectedID == id { selectedID = meetings.first?.id }
    }

    func revealInFinder(_ id: UUID) {
        guard let m = meeting(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.folder(for: m)])
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
