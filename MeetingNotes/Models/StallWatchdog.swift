import Foundation

/// Notices a track that delivers no audio although its capture reported no error. Pure logic.
///
/// A running capture delivers buffers all the time, also when it is quiet. If none arrive, the
/// engine or the tap died without a notification (after a device hiccup, for example), and
/// nothing else would bring the track back.
struct StallWatchdog {
    /// Seconds without audio before the capture is restarted.
    var stallAfter: Double = 3
    /// Seconds without audio before the user is told.
    var warnAfter: Double = 12
    var backoff = RestartBackoff()

    private var restarts = 0
    private var nextRestart: Double = 0

    /// Returns true when the capture should be restarted now. Feed it a few times per second.
    mutating func update(silentFor: Double, at time: Double) -> Bool {
        guard silentFor >= stallAfter else {
            restarts = 0
            nextRestart = 0
            return false
        }
        guard time >= nextRestart else { return false }
        restarts += 1
        // Leave the restart enough time to deliver its first audio before the next one.
        nextRestart = time + stallAfter + backoff.delay(afterFailures: restarts)
        return true
    }

    func shouldWarn(silentFor: Double) -> Bool {
        silentFor >= warnAfter
    }
}
