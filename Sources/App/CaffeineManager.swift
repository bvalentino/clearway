import IOKit.pwr_mgt
import SwiftUI

/// Holds an IOPMAssertion that prevents display + idle system sleep
/// (and therefore screensaver) while `isActive` is true.
///
/// State is intentionally not persisted: on app relaunch we start OFF,
/// matching `caffeinate`'s lifetime semantics and avoiding a
/// user-invisible perma-lock if the app was force-quit while active.
@MainActor
final class CaffeineManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    private var assertionID: IOPMAssertionID = 0

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    private func activate() {
        guard !isActive else { return }
        var id: IOPMAssertionID = 0
        let reason = "Clearway caffeine mode" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        assertionID = id
        isActive = true
    }

    private func deactivate() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}
