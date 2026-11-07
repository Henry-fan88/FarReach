import XCTest
import RemoteCore
@testable import FarReach

final class UpdateInstallGateTests: XCTestCase {
    @MainActor func testRestartWaitsForIdleAndRunsOnlyOnce() async {
        let gate = UpdateInstallGate()
        var busy = true, calls = 0
        gate.isBusy = { busy }
        gate.enqueue { calls += 1 }
        await nextMainTurn()
        XCTAssertEqual(calls, 0)
        busy = false
        gate.resumeIfIdle(); gate.resumeIfIdle()
        await nextMainTurn()
        XCTAssertEqual(calls, 1)
        gate.resumeIfIdle()
        await nextMainTurn()
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testNewSessionBeforeScheduledRestartDefersAgain() async {
        let gate = UpdateInstallGate()
        var busy = false, calls = 0
        gate.isBusy = { busy }
        gate.enqueue { calls += 1 }
        busy = true
        await nextMainTurn()
        XCTAssertEqual(calls, 0)
        busy = false; gate.resumeIfIdle()
        await nextMainTurn()
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testCancelledUpdateCannotRestartLater() async {
        let gate = UpdateInstallGate()
        gate.isBusy = { false }
        var calls = 0
        gate.enqueue { calls += 1 }
        gate.cancel()
        await nextMainTurn()
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testHostStandbyAndPausedViewerPreventRestart() {
        let model = AppModel(pairingStore: InMemoryPairingStore())
        XCTAssertFalse(model.preventsUpdateRestart)
        model.isHosting = true
        XCTAssertTrue(model.preventsUpdateRestart)
        model.isHosting = false; model.canResumeViewing = true
        XCTAssertTrue(model.preventsUpdateRestart)
        model.canResumeViewing = false; model.isConnecting = true
        XCTAssertTrue(model.preventsUpdateRestart)
        model.isConnecting = false; model.diagnosticRunning = true
        XCTAssertTrue(model.preventsUpdateRestart)
        model.diagnosticRunning = false
        XCTAssertFalse(model.preventsUpdateRestart)
    }

    @MainActor private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
