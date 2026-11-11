import Foundation

/// Decides when a call is over during a recording. Pure logic, fed about once per second.
///
/// A recording counts as a call once another app (Zoom, Teams, a browser, …) held the
/// microphone for `armAfter` seconds. The call is over when no other app uses the mic and
/// the call audio is quiet for `endAfter` seconds in a row.
struct CallEndTracker {
    var armAfter: Double = 10
    var endAfter: Double = 10

    private(set) var armed = false
    private var micInUseSince: Double?
    private var idleSince: Double?

    /// Returns true once, when the call has ended.
    mutating func update(otherAppUsesMic: Bool, callAudioActive: Bool, at time: Double) -> Bool {
        if otherAppUsesMic {
            idleSince = nil
            let since = micInUseSince ?? time
            micInUseSince = since
            if time - since >= armAfter { armed = true }
            return false
        }
        micInUseSince = nil
        guard armed else { return false }
        if callAudioActive {
            idleSince = nil
            return false
        }
        let since = idleSince ?? time
        idleSince = since
        guard time - since >= endAfter else { return false }
        armed = false
        idleSince = nil
        return true
    }
}
