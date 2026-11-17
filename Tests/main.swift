import AppKit
import Carbon
import ApplicationServices

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

final class FakeWindow {
    var minimized = false
    var fullScreen = false
    var subrole: String = kAXStandardWindowSubrole
    var writable = true
    var writeError: AXError = .success
    var applyWrite = true
    var readError: AXError?
    var writes: [Bool] = []
    var delay: TimeInterval = 0
    var pending: (TimeInterval, Bool)?
}

final class FakeAccess: WindowAccess {
    typealias Element = FakeWindow
    var applications: [pid_t: [FakeWindow]] = [:]
    var failures: [pid_t: AXError] = [:]
    var calls: [pid_t] = []
    var time: TimeInterval = 0
    var queryCost: TimeInterval = 0
    var writeTimes: [TimeInterval] = []
    var operations: [String] = []
    var afterWrite: (() -> Void)?
    func windows(pid: pid_t) -> AccessResult<[FakeWindow]> {
        calls.append(pid); time += queryCost
        if let error = failures[pid] { return .failure(error) }
        return .success(applications[pid] ?? [])
    }
    func bool(_ element: FakeWindow, _ attribute: String) -> AccessResult<Bool> {
        operations.append("read")
        if let error = element.readError { return .failure(error) }
        if let pending = element.pending, time >= pending.0 { element.minimized = pending.1; element.pending = nil }
        return .success(attribute == "AXFullScreen" ? element.fullScreen : element.minimized)
    }
    func string(_ element: FakeWindow, _ attribute: String) -> String? { element.subrole }
    func canWriteMinimized(_ element: FakeWindow) -> Bool { element.writable }
    func setMinimized(_ element: FakeWindow, _ minimized: Bool) -> AXError {
        operations.append(minimized ? "minimize" : "restore")
        writeTimes.append(time)
        element.writes.append(minimized)
        if element.applyWrite {
            if element.delay > 0 { element.pending = (time + element.delay, minimized) }
            else { element.minimized = minimized }
        }
        afterWrite?()
        return element.writeError
    }
    func same(_ lhs: FakeWindow, _ rhs: FakeWindow) -> Bool { lhs === rhs }
}

func target(_ pid: pid_t = 100) -> WindowTarget { WindowTarget(pid: pid, name: "测试应用 \(pid)") }
func engine(_ access: FakeAccess) -> WindowEngine<FakeAccess> {
    WindowEngine(access: access, now: { access.time }, pause: { access.time += $0 })
}

do {
    let access = FakeAccess()
    let regular = FakeWindow(), old = FakeWindow(), full = FakeWindow(), dialog = FakeWindow(), fixed = FakeWindow()
    old.minimized = true; full.fullScreen = true; dialog.subrole = kAXDialogSubrole; fixed.writable = false
    access.applications[100] = [regular, old, full, dialog, fixed]
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 1 && report.already == 1 && report.skipped == 3 && report.failed == 0, "mixed window result is accurate")
    expect(saved.count == 1, "only newly minimized window is saved")
    expect(full.writes.isEmpty && dialog.writes.isEmpty && fixed.writes.isEmpty && old.writes.isEmpty, "fullscreen, dialogs and existing minimized windows untouched")
    let (restored, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(restored == 1 && pending.isEmpty && !regular.minimized, "restore newly minimized window")
    expect(old.minimized, "pre-existing minimized window remains minimized")
}

do {
    let access = FakeAccess(), window = FakeWindow()
    window.writeError = .cannotComplete
    access.applications[100] = [window]
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 1 && saved.count == 1, "timeout followed by positive readback counts as success")
}
do {
    let access = FakeAccess(), window = FakeWindow()
    window.applyWrite = false
    access.applications[100] = [window]
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 0 && report.failed == 1, "write success without confirmation is not success")
    expect(saved.count == 1, "uncertain write retained for recovery")
}
do {
    let access = FakeAccess(), window = FakeWindow()
    window.applyWrite = false; window.writeError = .notImplemented
    access.applications[100] = [window]; access.failures[101] = .apiDisabled
    let (report, saved) = engine(access).minimize([target(), target(101)], cancelled: { false })
    expect(report.failed == 2 && report.succeeded == 0 && saved.isEmpty, "permission and unsupported writes reported accurately")
}
do {
    let access = FakeAccess(), window = FakeWindow()
    window.readError = .cannotComplete; access.applications[100] = [window]
    let (report, _) = engine(access).minimize([target()], cancelled: { false })
    expect(report.failed == 1 && window.writes.isEmpty, "state read failure does not change window")
}
do {
    let access = FakeAccess(); access.queryCost = 4
    access.applications[100] = [FakeWindow()]
    var worker = engine(access); worker.globalBudget = 3
    let (report, _) = worker.minimize([target(), target(101)], cancelled: { false })
    expect(report.interrupted && access.calls == [100], "global budget stops following applications")
}
do {
    let access = FakeAccess()
    let (report, _) = engine(access).minimize([target()], cancelled: { true })
    expect(report.interrupted && access.calls.isEmpty, "cancellation stops before window access")
}
do {
    let access = FakeAccess(), userRestored = FakeWindow(), closed = FakeWindow(), failed = FakeWindow()
    closed.readError = .invalidUIElement; failed.minimized = true; failed.applyWrite = false
    let saved = [userRestored, closed, failed].map { EngineSaved(pid: 100, application: "测试", element: $0) }
    let (count, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(count == 0 && pending.count == 1, "closed and user-restored windows removed; failed restore retained")
    expect(userRestored.writes.isEmpty && closed.writes.isEmpty, "restore never touches restored or closed windows")
}
do {
    let access = FakeAccess(), window = FakeWindow()
    window.minimized = true; window.readError = .apiDisabled
    let saved = [EngineSaved(pid: 100, application: "测试", element: window)]
    let (_, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(pending.count == 1 && window.writes.isEmpty, "permission revoked preserves recovery intent")
}
do {
    let flag = CancellationFlag()
    expect(!flag.cancelled, "cancel defaults false"); flag.cancel(); expect(flag.cancelled, "cancel updates")
    expect(Shortcut.standard.isValid, "default shortcut valid")
    expect(!Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: 0, label: "M").isValid, "plain letter rejected")
    expect(!Shortcut(keyCode: 999, modifiers: UInt32(cmdKey), label: "M").isValid, "invalid keycode rejected")
    expect(!Shortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey), label: "⌘").isValid, "modifier only rejected")
    let data = try JSONEncoder().encode(Shortcut.standard)
    let decoded = try JSONDecoder().decode(Shortcut.self, from: data)
    expect(decoded == .standard, "shortcut survives serialization")
}

do {
    let access = FakeAccess(), window = FakeWindow()
    window.delay = 0.6; access.applications[100] = [window]
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 1 && saved.count == 1, "wait for asynchronous minimize animation")
    let (count, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(count == 1 && pending.isEmpty, "wait for asynchronous restore animation")
}
do {
    let access = FakeAccess(), window = FakeWindow()
    access.applications[100] = [window]
    let (_, _) = engine(access).minimize([target()], cancelled: { false })
    window.minimized = false
    let (report, savedAgain) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 1 && savedAgain.count == 1, "repeated minimization produces a fresh batch")
}

do {
    let access = FakeAccess()
    let first = FakeWindow(), keptFromEarlier = FakeWindow(), newWindow = FakeWindow(), originallyMinimized = FakeWindow()
    originallyMinimized.minimized = true
    access.applications[100] = [first, keptFromEarlier, originallyMinimized]
    var batch = LastWindowBatch<EngineSaved<FakeWindow>>()
    expect(batch.nextAction == .minimize, "first shortcut action minimizes")
    let (_, roundOne) = engine(access).minimize([target()], cancelled: { false })
    batch.replace(with: roundOne)
    expect(batch.windows.count == 2 && batch.nextAction == .restore, "second shortcut action restores only latest batch")

    // A new minimize round after some manual window changes must replace the old batch.
    // One window from the earlier round stays minimized throughout.
    first.minimized = false
    access.applications[100] = [first, keptFromEarlier, newWindow, originallyMinimized]
    let (_, roundTwo) = engine(access).minimize([target()], cancelled: { false })
    batch.replace(with: roundTwo)
    expect(batch.windows.count == 2, "new round replaces rather than accumulates earlier batch")
    expect(batch.windows.contains(where: { $0.element === first }) && batch.windows.contains(where: { $0.element === newWindow }), "latest batch contains only windows newly collected in round two")
    expect(!batch.windows.contains(where: { $0.element === keptFromEarlier || $0.element === originallyMinimized }), "earlier and originally minimized windows excluded")
    let (restored, pending, _) = engine(access).restore(batch.windows, cancelled: { false })
    batch.finishRestore(pending: pending)
    expect(restored == 2 && !first.minimized && !newWindow.minimized, "restore reopens precisely latest batch")
    expect(keptFromEarlier.minimized && originallyMinimized.minimized, "restore leaves earlier and user-minimized windows closed")
    expect(batch.windows.isEmpty && batch.nextAction == .minimize, "third shortcut starts a fresh minimize cycle")
}
do {
    let access = FakeAccess(), successful = FakeWindow(), failed = FakeWindow()
    access.applications[100] = [successful, failed]
    var batch = LastWindowBatch<EngineSaved<FakeWindow>>()
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    batch.replace(with: saved)
    failed.applyWrite = false
    let (count, pending, _) = engine(access).restore(batch.windows, cancelled: { false })
    batch.finishRestore(pending: pending)
    expect(count == 1 && batch.windows.count == 1 && batch.windows[0].element === failed, "partial restore keeps only failures in latest batch")
    expect(batch.nextAction == .restore, "next shortcut retries pending restoration instead of minimizing more")
    failed.applyWrite = true
    let (retryCount, retryPending, _) = engine(access).restore(batch.windows, cancelled: { false })
    batch.finishRestore(pending: retryPending)
    expect(retryCount == 1 && batch.nextAction == .minimize, "successful retry returns to minimize mode")
    expect(successful.writes == [true, false], "successful prior restore is not repeated")
}
do {
    var batch = LastWindowBatch<Int>()
    batch.replace(with: [1, 2])
    batch.replace(with: [])
    expect(batch.windows.isEmpty && batch.nextAction == .minimize, "empty latest round cannot expose historical windows")
}

do {
    let access = FakeAccess()
    let windows = (0..<8).map { _ -> FakeWindow in let window = FakeWindow(); window.delay = 0.6; return window }
    access.applications[100] = Array(windows.prefix(4))
    access.applications[101] = Array(windows.suffix(4))
    var callbackCount = 0
    let (report, saved) = engine(access).minimize([target(), target(101)], cancelled: { false }, onRequestsDispatched: {
        callbackCount += 1; access.operations.append("local")
    })
    expect(report.succeeded == 8 && saved.count == 8, "batch minimizes windows across applications")
    expect(access.writeTimes.count == 8 && Set(access.writeTimes).count == 1, "all writes precede every animation wait")
    let firstWrite = access.operations.firstIndex(of: "minimize")!
    expect(Array(access.operations[firstWrite..<(firstWrite + 8)]) == Array(repeating: "minimize", count: 8), "no readback between minimize writes")
    expect(access.operations[firstWrite + 8] == "local" && callbackCount == 1, "local window request joins burst before readback")
    expect(access.time < 0.8, "eight animations share one settle interval instead of eight")
    access.operations = []; access.writeTimes = []
    let restoreStart = access.time
    let (count, pending, _) = engine(access).restore(saved, cancelled: { false }, onRequestsDispatched: { access.operations.append("local") })
    expect(count == 8 && pending.isEmpty, "batch restoration confirms all windows")
    expect(Set(access.writeTimes).count == 1, "restore writes do not wait for earlier animations")
    let firstRestore = access.operations.firstIndex(of: "restore")!
    expect(Array(access.operations[firstRestore..<(firstRestore + 8)]) == Array(repeating: "restore", count: 8), "no readback between restore requests")
    expect(access.operations[firstRestore + 8] == "local" && access.time - restoreStart < 0.8, "local restore and shared verification do not add per-window delay")
}
do {
    let access = FakeAccess(), slow = FakeWindow(), quick = FakeWindow()
    slow.delay = 2; quick.delay = 0.24
    access.applications[100] = [slow, quick]
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 1 && report.failed == 1 && saved.count == 2, "one slow animation does not block another; uncertain write is recoverable")
    expect(access.writeTimes == [0, 0], "slow first window cannot delay later write")
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    first.delay = 0.6
    access.applications[100] = [first, second]
    let cancel = CancellationFlag()
    access.afterWrite = { cancel.cancel() }
    var localCalled = false
    let (report, saved) = engine(access).minimize([target()], cancelled: { cancel.cancelled }, onRequestsDispatched: { localCalled = true })
    expect(first.writes == [true] && second.writes.isEmpty, "cancellation stops unsent requests")
    expect(report.interrupted && saved.count == 1 && saved[0].element === first, "cancel preserves already issued uncertain request")
    expect(!localCalled, "cancellation prevents local request")
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    first.minimized = true; second.minimized = true
    first.delay = 0.6
    let saved = [first, second].map { EngineSaved(pid: 100, application: "测试", element: $0) }
    let cancel = CancellationFlag()
    access.afterWrite = { cancel.cancel() }
    let (count, pending, _) = engine(access).restore(saved, cancelled: { cancel.cancelled })
    expect(count == 0 && pending.count == 2, "cancelled restore keeps issued uncertain and unsent snapshots")
    expect(first.writes == [false] && second.writes.isEmpty, "cancelled restore does not write later windows")
}

do {
    let access = FakeAccess()
    let windows = (0..<3).map { _ -> FakeWindow in let window = FakeWindow(); window.delay = 0.6; return window }
    access.applications[100] = windows
    var callbackTime: TimeInterval = -1
    let (report, saved) = engine(access).minimize([target()], mode: .sequential, cancelled: { false }, onRequestsDispatched: { callbackTime = access.time })
    expect(report.succeeded == 3 && saved.count == 3, "sequential mode saves exactly its successful batch")
    expect(access.writeTimes.count == 3 && access.writeTimes[1] - access.writeTimes[0] >= 0.6 && access.writeTimes[2] - access.writeTimes[1] >= 0.6, "sequential mode waits before issuing next window")
    expect(callbackTime >= 1.8, "own window is requested after sequential window confirmations")
    let first = access.operations.firstIndex(of: "minimize")!
    expect(access.operations[first + 1] == "read", "sequential mode reads state before next write")
    let (restored, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(restored == 3 && pending.isEmpty, "sequential batch retains normal last-batch restoration")
}
do {
    let access = FakeAccess(), slow = FakeWindow(), quick = FakeWindow()
    slow.delay = 3; quick.delay = 0.24
    access.applications[100] = [slow, quick]
    let (report, saved) = engine(access).minimize([target()], mode: .sequential, cancelled: { false })
    expect(report.failed == 1 && report.succeeded == 1 && saved.count == 2, "sequential confirmation timeout retains uncertain intent and continues")
    expect(access.writeTimes[1] >= 1.19 && access.writeTimes[1] <= 1.21, "sequential timeout wait is bounded")
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    first.delay = 0.6
    access.applications[100] = [first, second]
    let cancel = CancellationFlag(); access.afterWrite = { cancel.cancel() }
    let (report, saved) = engine(access).minimize([target()], mode: .sequential, cancelled: { cancel.cancelled })
    expect(report.interrupted && second.writes.isEmpty && saved.count == 1, "sequential cancellation retains only issued request")
}
do {
    let access = FakeAccess()
    let windows = (0..<4).map { _ -> FakeWindow in let window = FakeWindow(); window.delay = 0.6; return window }
    access.applications[100] = windows
    var worker = engine(access); worker.globalBudget = 0.8
    let (report, saved) = worker.minimize([target()], mode: .sequential, cancelled: { false })
    expect(report.interrupted && access.writeTimes.count == 2 && saved.count == 2, "sequential mode respects overall timeout without losing issued requests")
}
for mode in MinimizeMode.allCases {
    let access = FakeAccess(), old = FakeWindow(), newWindow = FakeWindow(), dialog = FakeWindow()
    old.minimized = true; dialog.subrole = kAXDialogSubrole
    access.applications[100] = [old, newWindow, newWindow, dialog]
    let (report, saved) = engine(access).minimize([target()], mode: mode, cancelled: { false })
    expect(report.succeeded == 1 && saved.count == 1 && newWindow.writes == [true], "both modes deduplicate and exclude previous minimized windows")
    let (_, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(pending.isEmpty && old.minimized && !newWindow.minimized, "both modes restore only latest newly collected windows")
    expect(MinimizeMode(rawValue: mode.rawValue) == mode, "mode raw value roundtrips for settings")
}
expect(MinimizeMode(rawValue: "unsupported") == nil, "invalid stored mode rejected")

final class FakeBarAccess: SystemBarAccess {
    var state: BarState
    var writes: [(BarState, BarTargets)] = []
    var reads = 0
    var failRead = false
    var failWriteOnce = false
    var ignoreWriteOnce = false
    init(_ state: BarState) { self.state = state }
    func read() throws -> BarState {
        reads += 1
        if failRead { throw SystemBarError.automationDenied }
        return state
    }
    func write(_ new: BarState, targets: BarTargets) throws {
        writes.append((new, targets))
        if ignoreWriteOnce { ignoreWriteOnce = false; return }
        if targets.menuBar { state.menuBar = new.menuBar }
        if failWriteOnce { failWriteOnce = false; throw SystemBarError.execution("partial write") }
        if targets.dock { state.dock = new.dock }
    }
}

for menu in [false, true] {
    for dock in [false, true] {
        for targets in [BarTargets(menuBar: true, dock: false), BarTargets(menuBar: false, dock: true), BarTargets()] {
            let access = FakeBarAccess(BarState(menuBar: menu, dock: dock))
            let controller = SystemBarController(access: access)
            let result = try controller.toggle(targets)
            let hide = !((!targets.menuBar || menu) && (!targets.dock || dock))
            expect(result.menuBar == (targets.menuBar ? hide : menu), "menu bar only follows selected target")
            expect(result.dock == (targets.dock ? hide : dock), "dock only follows selected target")
            expect(access.reads == 2 && access.writes.count == 1, "system setting is read before and verified after mutation")
            let second = try controller.toggle(targets)
            expect(second.menuBar == (targets.menuBar ? !hide : menu) && second.dock == (targets.dock ? !hide : dock), "second invocation shows selected system bars and preserves unselected state")
        }
    }
}
do {
    let access = FakeBarAccess(BarState(menuBar: false, dock: true))
    do { _ = try SystemBarController(access: access).toggle(BarTargets(menuBar: false, dock: false)); expect(false, "empty targets rejected") }
    catch { expect(access.reads == 0 && access.writes.isEmpty, "empty targets do not access system settings") }
}
do {
    let access = FakeBarAccess(BarState(menuBar: false, dock: true)); access.failRead = true
    do { _ = try SystemBarController(access: access).toggle(BarTargets()); expect(false, "denied automation rejected") }
    catch { expect(access.writes.isEmpty, "automation denial never changes settings") }
}
do {
    let before = BarState(menuBar: false, dock: false)
    let access = FakeBarAccess(before); access.failWriteOnce = true
    do { _ = try SystemBarController(access: access).toggle(BarTargets()); expect(false, "partial failure rejected") }
    catch { expect(access.state == before && access.writes.count == 2, "partial setting write rolls back selected settings") }
}
do {
    let before = BarState(menuBar: false, dock: true)
    let access = FakeBarAccess(before); access.ignoreWriteOnce = true
    do { _ = try SystemBarController(access: access).toggle(BarTargets(menuBar: true, dock: false)); expect(false, "unconfirmed result rejected") }
    catch {
        expect(access.state == before && access.writes.count == 2, "verification mismatch restores original selected preference")
        expect(access.writes.allSatisfy { !$0.1.dock }, "rollback never touches unselected dock")
    }
}
expect(Shortcut.barsStandard.isValid && !Shortcut.barsStandard.matches(.standard), "default hotkeys are valid and independent")
expect(Shortcut(keyCode: Shortcut.standard.keyCode, modifiers: Shortcut.standard.modifiers, label: "different label").matches(.standard), "duplicate detection uses physical shortcut rather than display label")
let selected = BarTargets(menuBar: false, dock: true)
let serialized = try JSONEncoder().encode(selected)
let decodedTargets = try JSONDecoder().decode(BarTargets.self, from: serialized)
expect(decodedTargets == selected, "multi-select targets serialize independently")

func layer(_ id: Int, _ kind: EscapeLayerKind, close: Int? = nil, cancel: Int? = nil, nativeCancel: Bool = false) -> EscapeLayer<Int> {
    EscapeLayer(element: id, kind: kind, close: close, cancel: cancel, supportsCancel: nativeCancel)
}
do {
    let result = EscapeSelectionPolicy.select([layer(1, .window, close: 10)])
    expect(result?.layer == 1 && result?.control == 10 && result?.action == .closeButton, "ordinary window requests its own normal close")
    expect(EscapeSelectionPolicy.select([layer(1, .window)]) == nil, "disabled close is not forced")
}
do {
    let result = EscapeSelectionPolicy.select([layer(2, .overlay, close: 20), layer(1, .window, close: 10)])
    expect(result?.layer == 2 && result?.control == 20, "top preview closes without choosing parent")
    expect(EscapeSelectionPolicy.select([layer(2, .overlay), layer(1, .window, close: 10)]) == nil, "unclosable overlay never falls through to parent")
    let cancel = EscapeSelectionPolicy.select([layer(2, .overlay, cancel: 21)])
    expect(cancel?.control == 21 && cancel?.action == .cancelButton, "dialog cancel control is normal native cancellation")
    let direct = EscapeSelectionPolicy.select([layer(2, .overlay, nativeCancel: true)])
    expect(direct?.control == 2 && direct?.action == .cancel, "semantic cancel action closes only overlay")
}
do {
    // Internal page controls never enter the ordered top-level layer list.
    let result = EscapeSelectionPolicy.select([layer(1, .window, close: 10)])
    expect(result?.control == 10 && result?.control != 99, "tab close button is never used instead of window control")
    expect(EscapeSelectionPolicy.select([layer(3, .content, close: 99), layer(1, .window, close: 10)]) == nil, "content is not a closable top-level surface")
}
for route in [EscapeTransaction.Route.native, .close] {
    var press = EscapeTransaction()
    expect(press.resolve(route), "one physical press commits one action")
    expect(!press.resolve(.native) && !press.resolve(.close), "same ESC cannot cancel overlay and close exposed parent")
}
do {
    var first = EscapeTransaction()
    let target = EscapeSelectionPolicy.select([layer(2, .overlay, close: 20), layer(1, .window, close: 10)])!
    expect(first.resolve(.close) && target.control == 20, "first key targets image overlay")
    let exposedParent = EscapeSelectionPolicy.select([layer(1, .window, close: 10)])!
    expect(!first.resolve(.close), "late event for same physical press cannot use exposed parent")
    var second = EscapeTransaction()
    expect(second.resolve(.close) && exposedParent.control == 10, "separate second physical press targets main window")
}
do {
    var press = EscapeTransaction()
    expect(press.resolve(.native), "screenshot Escape delivered to system")
    expect(!press.resolve(.close), "native screenshot cancel cannot later close underlying app")
}
do {
    var press = EscapeTransaction(); press.cancel()
    expect(!press.resolve(.close) && !press.resolve(.native), "cancelled operation stays cancelled")
}
expect(EscapeSelectionPolicy.mayCloseSameTarget(sameRoot: true, sameLayer: true, sameControl: true, cancelled: false), "stable current top layer may close")
for flags in [(false,true,true,false), (true,false,true,false), (true,true,false,false), (true,true,true,true)] {
    expect(!EscapeSelectionPolicy.mayCloseSameTarget(sameRoot: flags.0, sameLayer: flags.1, sameControl: flags.2, cancelled: flags.3), "focus/layer/control change or cancellation prevents stale close")
}
// Saving is not a branch: one normal close request is committed, whatever dialog
// the application presents afterwards belongs to the app, not a second action.
do {
    var press = EscapeTransaction()
    let result = EscapeSelectionPolicy.select([layer(1, .window, close: 10)])
    expect(result?.action == .closeButton && press.resolve(.close), "unsaved document receives one normal close request")
    expect(!press.resolve(.close) && !press.resolve(.native), "save prompt cannot receive a second action from same press")
}
expect(EscapeSelectionPolicy.actionTimeout >= 1.5, "normal close actions do not inherit discovery timeout")
expect(!EscapeSelectionPolicy.blocksForForeignWindow(layer: 0, width: 1920, height: 1080), "ordinary VM/app ahead is not a capture overlay")
expect(EscapeSelectionPolicy.blocksForForeignWindow(layer: 1000, width: 1920, height: 1080), "screen capture layer keeps native cancel")
expect(EscapeSelectionPolicy.isCancelControl(identifier: "CancelButton", title: nil, role: kAXButtonRole, enabled: true), "standard save sheet child Cancel supported")
expect(!EscapeSelectionPolicy.isCancelControl(identifier: "DontSaveButton", title: "删除", role: kAXButtonRole, enabled: true), "never choose discard document")
expect(!EscapeSelectionPolicy.isCancelControl(identifier: "OKButton", title: "保存", role: kAXButtonRole, enabled: true), "never choose Save automatically")
expect(!EscapeSelectionPolicy.isCancelControl(identifier: "CancelButton", title: "取消", role: kAXButtonRole, enabled: false), "disabled cancel cannot be chosen")
expect(!EscapeSelectionPolicy.mayForwardUnknown(isRecognizedOverlay: false), "failed ordinary-window detection must not replay ESC and close an internal page")
expect(EscapeSelectionPolicy.mayForwardUnknown(isRecognizedOverlay: true), "identified native overlay may receive original cancellation")
expect(!EscapeSelectionPolicy.blocksForForeignWindow(layer: 20, width: 1920, height: 1080, systemAuxiliary: true), "Dock system helper is not a screenshot blocker")
expect(!EscapeSelectionPolicy.blocksForForeignWindow(layer: 3, width: 500, height: 300, systemAuxiliary: true), "known system auxiliary layer does not disable every application")
expect(EscapeSelectionPolicy.blocksForForeignWindow(layer: 1000, width: 1920, height: 1080, systemAuxiliary: false), "third-party screenshot selection retains native Escape")
do {
    var press = EscapeTransaction()
    press.cancel()
    expect(!press.resolve(.native) && !press.resolve(.close), "failed ordinary inspection cannot replay key and close a tab")
}
// Fullscreen takes precedence over the overlay's own windowed state. AX failures
// must not become permission to close; unsupported optional attributes stay compatible.
do {
    let evaluate = EscapeFullScreenPolicy.evaluate
    let permits = EscapeFullScreenPolicy.permitsClose
    expect(!permits(evaluate([.fullScreen])), "fullscreen window cannot close")
    expect(!permits(evaluate([.windowed, .fullScreen])), "fullscreen parent protects its floating panel")
    expect(!permits(evaluate([.unsupported, .fullScreen])), "unsupported sheet cannot bypass fullscreen owner")
    expect(!permits(evaluate([.unavailable, .fullScreen])), "known fullscreen remains protected even when another query fails")
    expect(permits(evaluate([.windowed])), "ordinary window retains close behavior")
    expect(permits(evaluate([.windowed, .windowed])), "ordinary overlay and owner retain close behavior")
    expect(permits(evaluate([.unsupported])), "apps without optional fullscreen attribute still work")
    expect(!permits(evaluate([.unavailable])), "fullscreen lookup timeout cannot authorize close")
    expect(!permits(evaluate([.windowed, .unavailable])), "owner query failure cannot authorize close")
    expect(!permits(evaluate([])), "missing fullscreen inspection cannot authorize close")
    let before = evaluate([.windowed]), after = evaluate([.fullScreen])
    expect(permits(before) && !permits(after), "entering fullscreen before execution blocks a previously prepared action")
    expect(permits(evaluate([.windowed])), "leaving fullscreen re-enables ordinary close on a separate key")
}
print("PASS: \(checks) assertions; fullscreen protection, action timeout, save-sheet cancel and original features.")
