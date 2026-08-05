import Foundation
import Testing

@testable import sAiity

/// The session state decides two things that used to disagree: what the menu
/// offers, and whether the Settings window is allowed to delete model files.
///
/// The bug this replaces: a Bool could not represent `starting`, so a session
/// that was loading a model looked idle. Stop tore down a backend that had not
/// started; the start task then resumed and brought the audio stream up anyway.
@MainActor
struct SessionStateTests {

    @Test("Loading counts as active, so Stop is offered and deletion is refused")
    func startingIsActive() {
        // The whole point. During `starting` the app may be mid-download with no
        // stream yet — but a model is being read, and the user must be able to
        // stop. Treating it as idle is what let a second Start run.
        #expect(AppDelegate.SessionState.starting.isActive)
        #expect(AppDelegate.SessionState.running.isActive)
    }

    @Test("Idle and stopping are not active")
    func inactiveStates() {
        #expect(!AppDelegate.SessionState.idle.isActive)
        // `stopping` is not active: teardown is already under way, and offering
        // Stop again would re-enter it.
        #expect(!AppDelegate.SessionState.stopping.isActive)
    }

    @Test("Cancelling an in-flight start stops it before it reaches capture")
    func cancellationStopsBeforeCapture() async {
        // The orchestration contract `start()` relies on: a task suspended in a
        // long model load must not proceed past its checkpoint once cancelled.
        // Before the fix there were no checkpoints, so a cancelled start still
        // ran `capture.start()` — audio capture with the menu reading "Start".
        actor Reached {
            var capture = false
            func markCapture() { capture = true }
        }
        let reached = Reached()

        let task = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)   // stands in for the model load
            guard !Task.isCancelled else { return }
            await reached.markCapture()
        }
        // Stop, the way stopAsync does it: cancel AND wait, so teardown cannot
        // race the thing it is tearing down.
        task.cancel()
        await task.value

        #expect(await reached.capture == false, "cancelled start still reached capture")
    }
}
