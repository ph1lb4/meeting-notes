import Foundation

/// Notices a call whose audio never arrives. Pure logic, fed about once per second.
///
/// Without the "System Audio Recording" permission the tap still runs, but delivers only zeros.
/// macOS has no call to ask for the permission state, so this looks at the result: another app
/// holds the microphone (a call) for `warnAfter` seconds and the call track never had a sound.
struct SilentCallCheck {
    var warnAfter: Double = 45

    private var micInUseSince: Double?
    private var done = false

    /// Returns true once, when the user should be told.
    mutating func update(otherAppUsesMic: Bool, callAudioHeard: Bool, at time: Double) -> Bool {
        if callAudioHeard { done = true }
        guard !done, otherAppUsesMic else {
            micInUseSince = nil
            return false
        }
        let since = micInUseSince ?? time
        micInUseSince = since
        guard time - since >= warnAfter else { return false }
        done = true
        return true
    }
}
