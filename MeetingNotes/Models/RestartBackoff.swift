import Foundation

/// Wait times between attempts to bring a dead audio track (mic or call audio) back. Pure logic.
///
/// Capture never gives up while a recording runs: a device can take many seconds to come back
/// (Bluetooth switching profiles, a dock waking up), and a track that stays dead loses the meeting.
struct RestartBackoff {
    var firstDelay: Double = 0.5
    var maxDelay: Double = 5
    /// Failed attempts in a row before the user is told. Short hiccups while a device switches stay quiet.
    var warnAfter = 4

    /// Seconds to wait after the given number of failed attempts in a row (1 = first failure).
    func delay(afterFailures failures: Int) -> Double {
        let exponent = Double(min(max(failures, 1) - 1, 16))
        return min(firstDelay * pow(2, exponent), maxDelay)
    }

    func shouldWarn(afterFailures failures: Int) -> Bool {
        failures >= warnAfter
    }
}
