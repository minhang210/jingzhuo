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
    var onScreen = true
    var onScreenError: AXError?
    var role: String? = kAXWindowRole
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
    func string(_ element: FakeWindow, _ attribute: String) -> String? { attribute == kAXRoleAttribute ? element.role : element.subrole }
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
    func isOnScreen(_ element: FakeWindow, pid: pid_t) -> AccessResult<Bool> {
        if let error = element.onScreenError { return .failure(error) }
        return .success(element.onScreen)
    }
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

// Recovery state resets on real window changes, never app activation alone.
func inspector(_ access: FakeAccess, budget: TimeInterval = 1.5) -> RecoveryInspector<FakeAccess> {
    RecoveryInspector(access: access, now: { access.time }, globalBudget: budget)
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    access.applications[100] = [first, second]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(saved.allSatisfy(\.confirmedMinimized), "successful minimize snapshots record confirmed baseline")
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    let unchanged = inspector(access).inspect(baseline, targets: [target()])
    expect(!unchanged.reset && unchanged.saved.count == 2, "no window change preserves last batch without a timer")
    first.minimized = false
    let result = inspector(access).inspect(unchanged.baseline, targets: [target()])
    expect(result.reset && result.saved.isEmpty, "manual expansion of one window invalidates entire previous batch")
    expect(second.minimized && second.writes == [true], "forgetting recovery never expands or alters other windows")
    let (_, next) = engine(access).minimize([target()], cancelled: { false })
    expect(next.count == 1 && next[0].element === first, "next minimize only collects currently expanded windows")
}
do {
    let access = FakeAccess(), first = FakeWindow(), oldVisible = FakeWindow()
    oldVisible.writable = false; access.applications[100] = [first, oldVisible]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    expect(!inspector(access).inspect(baseline, targets: [target()]).reset, "unchanged unsupported visible window does not immediately reset")
    let newWindow = FakeWindow(); access.applications[100]?.append(newWindow)
    expect(inspector(access).inspect(baseline, targets: [target()]).reset, "new ordinary window in existing app resets recovery")
}
do {
    let access = FakeAccess(), first = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target(), target(101)])
    expect(!inspector(access).inspect(baseline, targets: [target(101), target()]).reset, "activation order alone does not reset")
    expect(!inspector(access).inspect(baseline, targets: [target(), target(102)]).reset, "new process without ordinary window does not reset")
    access.applications[102] = [FakeWindow()]
    expect(inspector(access).inspect(baseline, targets: [target(), target(102)]).reset, "new process showing ordinary window resets")
}
do {
    let access = FakeAccess(), first = FakeWindow(), image = FakeWindow(), content = FakeWindow(), full = FakeWindow()
    image.subrole = "AXFloatingWindow"; content.role = kAXGroupRole; full.fullScreen = true
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    access.applications[100]?.append(contentsOf: [image, content, full])
    expect(!inspector(access).inspect(baseline, targets: [target()]).reset, "floating preview, internal content and fullscreen do not count as new ordinary window")
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    access.applications[100] = [first]; access.applications[101] = [second]
    let (_, saved) = engine(access).minimize([target(), target(101)], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target(), target(101)])
    access.applications[100] = []
    let closed = inspector(access).inspect(baseline, targets: [target(), target(101)])
    expect(!closed.reset && closed.saved.count == 1 && closed.saved[0].pid == 101, "closed window prunes only itself without resetting other saved windows")
    let exited = inspector(access).inspect(baseline, targets: [target(101)])
    expect(!exited.reset && exited.saved.count == 1 && exited.saved[0].pid == 101, "terminated app prunes only its snapshots")
    let allGone = inspector(access).inspect(baseline, targets: [])
    expect(!allGone.reset && allGone.saved.isEmpty, "all windows gone returns naturally to minimize")
}
do {
    let access = FakeAccess(), first = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    access.failures[100] = .cannotComplete
    let unavailable = inspector(access).inspect(baseline, targets: [target()])
    expect(!unavailable.reset && unavailable.saved.count == 1 && unavailable.incomplete, "failed app query preserves recovery rather than pretending app closed")
    access.failures = [:]; first.readError = .cannotComplete
    let stateUnavailable = inspector(access).inspect(baseline, targets: [target()])
    expect(!stateUnavailable.reset && stateUnavailable.saved.count == 1, "failed minimized query does not pretend manual expansion")
}
do {
    let access = FakeAccess(), first = FakeWindow(), unknown = FakeWindow()
    access.applications[100] = [first];access.applications[101] = [unknown];access.failures[101] = .cannotComplete
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target(), target(101)])
    access.failures = [:]
    let readable = inspector(access).inspect(baseline, targets: [target(), target(101)])
    expect(!readable.reset, "previously unreadable app establishes neutral first baseline rather than false new window")
    access.applications[101]?.append(FakeWindow())
    expect(inspector(access).inspect(readable.baseline, targets: [target(), target(101)]).reset, "new window after previously unknown app baseline is detectable")
}
do {
    let access = FakeAccess(), first = FakeWindow(), uncertain = FakeWindow()
    uncertain.applyWrite = false;access.applications[100] = [first, uncertain]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(saved[0].confirmedMinimized && !saved[1].confirmedMinimized, "uncertain write is distinguishable from confirmed minimization")
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    let unchanged = inspector(access).inspect(baseline, targets: [target()])
    expect(!unchanged.reset && unchanged.saved.count == 2, "never-minimized uncertain window cannot invalidate new batch")
    uncertain.minimized = true
    let settled = inspector(access).inspect(unchanged.baseline, targets: [target()])
    expect(settled.saved.allSatisfy(\.confirmedMinimized), "later positive minimized readback promotes uncertain write")
    uncertain.minimized = false
    expect(inspector(access).inspect(settled.baseline, targets: [target()]).reset, "subsequent expansion of delayed minimize is detected")
}
do {
    let access = FakeAccess(), first = FakeWindow(), unknown = FakeWindow()
    access.applications[100] = [first, unknown]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    unknown.readError = .cannotComplete
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    unknown.readError = nil
    let next = inspector(access).inspect(baseline, targets: [target()])
    expect(!next.reset, "unknown initial window state becoming readable does not imply expansion")
}
do {
    let access = FakeAccess(), first = FakeWindow();first.minimized = true
    access.applications[100] = [first];access.queryCost = 2
    let saved = [EngineSaved(pid: 100, application: "测试", element: first, confirmedMinimized: true)]
    let result = inspector(access, budget: 0.2).inspect(RecoveryBaseline(knownPIDs: [100,101], saved: saved), targets: [target(), target(101)])
    expect(result.incomplete && access.calls == [100] && result.saved.count == 1 && !result.reset, "observation budget bounds following queries and preserves recovery")
    access.calls = []
    let cancelled = inspector(access).inspect(result.baseline, targets: [target()], cancelled: { true })
    expect(cancelled.incomplete && access.calls.isEmpty && cancelled.saved.count == 1, "cancelled observation performs no AX calls or destructive state transition")
}

do {
    let access = FakeAccess(), first = FakeWindow(), hiddenWindow = FakeWindow()
    first.minimized = true
    access.applications[100] = [first];access.applications[101] = [hiddenWindow]
    let saved = [EngineSaved(pid: 100, application: "测试", element: first, confirmedMinimized: true)]
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    let hiddenTarget = WindowTarget(pid: 101, name: "隐藏应用", isHidden: true)
    let hidden = inspector(access).inspect(baseline, targets: [target(), hiddenTarget])
    expect(!hidden.reset && hidden.saved.count == 1, "hidden app with AXMinimized false is not a visible new-window signal")
    let visible = inspector(access).inspect(hidden.baseline, targets: [target(), target(101)])
    expect(visible.reset, "explicit hidden-to-visible ordinary window transition resets recovery")
}

// Accepted delayed restore completion is our own operation, not user activity.
do {
    let access = FakeAccess(), delayed = FakeWindow(), failed = FakeWindow()
    access.applications[100] = [delayed, failed]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    delayed.delay = 2; failed.applyWrite = false; failed.writeError = .notImplemented
    let (_, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(pending.count == 2 && pending.contains(where: { $0.element === delayed && $0.restoreRequested }), "pending accepted restore keeps its operation source")
    expect(pending.contains(where: { $0.element === failed && !$0.restoreRequested }), "rejected restore is not falsely tagged as own expansion")
    let baseline = inspector(access).capture(saved: pending, targets: [target()])
    access.time += 2
    let completed = inspector(access).inspect(baseline, targets: [target()])
    expect(!completed.reset && completed.saved.count == 1 && completed.saved[0].element === failed, "delayed own restore completion only prunes its target, preserving other failed windows")
    expect(!completed.criticalUnknown, "remaining minimized target has readable recovery state")
    expect(!inspector(access).inspect(completed.baseline, targets: [target()]).reset, "later polls do not rediscover our completed restore as manual work")
    let newWindow = FakeWindow();access.applications[100]?.append(newWindow)
    expect(inspector(access).inspect(completed.baseline, targets: [target()]).reset, "own delayed completion does not suppress other newly opened windows")
}
do {
    let access = FakeAccess(), first = FakeWindow(), newWindow = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    newWindow.readError = .cannotComplete;access.applications[101] = [newWindow]
    let unknown = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101)
    expect(!unknown.reset && unknown.criticalUnknown && unknown.baseline.pendingNewPIDs.contains(101), "new app attribute failure remains pending without inventing a manual expansion")
    newWindow.readError = nil
    expect(inspector(access).inspect(unknown.baseline, targets: [target(), target(101)], criticalPID: 101).reset, "new app first readable visible window still invalidates batch after temporary failure")
}
do {
    let access = FakeAccess(), first = FakeWindow(), newWindow = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    newWindow.role = nil;access.applications[101] = [newWindow]
    let unknown = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101)
    expect(unknown.criticalUnknown && !unknown.reset, "unknown foreground role is not assumed to be a sheet or empty app")
    newWindow.role = kAXWindowRole
    expect(inspector(access).inspect(unknown.baseline, targets: [target(), target(101)], criticalPID: 101).reset, "new process origin survives temporary missing role")
}
do {
    let access = FakeAccess(), first = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target(), target(101)])
    access.failures[101] = .cannotComplete
    let background = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 100)
    expect(!background.criticalUnknown && background.incomplete, "unrelated unavailable background app does not block restoration")
    let foreground = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101)
    expect(foreground.criticalUnknown && !foreground.reset && foreground.saved.count == 1, "unavailable foreground query records uncertainty and preserves recovery targets")
    first.readError = .cannotComplete
    expect(inspector(access).inspect(baseline, targets: [target()]).criticalUnknown, "unknown saved window state is diagnostic rather than a whole-batch veto")
}
do {
    let access = FakeAccess(), first = FakeWindow(), sheet = FakeWindow()
    access.applications[100] = [first];sheet.subrole = kAXDialogSubrole;access.applications[101] = [sheet]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    expect(!inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101).criticalUnknown, "legitimate foreground sheet without ordinary window does not block decision")
    access.applications[101] = []
    expect(!inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101).criticalUnknown, "foreground app with positively empty window list is not unknown")
}

// A partial minimize report must not trap all confirmed windows behind one
// unresponsive or unconfirmed snapshot. Restore examines each saved window.
do {
    let access = FakeAccess()
    let regular = [FakeWindow(), FakeWindow(), FakeWindow()]
    let uncertain = FakeWindow(), old = FakeWindow()
    uncertain.applyWrite = false; old.minimized = true
    let skipped = (0..<4).map { _ -> FakeWindow in let w = FakeWindow(); w.writable = false; return w }
    access.applications[100] = regular + [uncertain, old] + skipped
    let (report, saved) = engine(access).minimize([target()], cancelled: { false })
    expect(report.succeeded == 3 && report.already == 1 && report.skipped == 4 && report.failed == 1,
           "reported 3 minimized / 1 already / 4 skipped / 1 unfinished is reproducible")
    expect(saved.count == 4 && saved.filter(\.confirmedMinimized).count == 3,
           "partial report retains all confirmed windows plus only uncertain accepted intent")
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    uncertain.readError = .cannotComplete
    let checked = inspector(access).inspect(baseline, targets: [target()])
    expect(!checked.reset && checked.criticalUnknown && checked.saved.count == 4,
           "one unreadable snapshot does not invent user activity or lose the three confirmed targets")
    let (restored, pending, _) = engine(access).restore(checked.saved, cancelled: { false })
    expect(restored == 3 && regular.allSatisfy { !$0.minimized },
           "three readable windows restore despite a fourth snapshot timing out")
    expect(regular.allSatisfy { $0.writes == [true, false] } && old.writes.isEmpty,
           "confirmed windows receive one restore and originally minimized window remains untouched")
    expect(pending.count == 1 && pending[0].element === uncertain,
           "only unreadable target is retained for a later retry")
    var batch = LastWindowBatch<EngineSaved<FakeWindow>>()
    batch.replace(with: checked.saved); batch.finishRestore(pending: pending)
    expect(batch.nextAction == .restore && batch.windows.count == 1,
           "partial restore remains a retry action instead of starting another minimize round")
    uncertain.readError = nil
    let (_, retried, _) = engine(access).restore(batch.windows, cancelled: { false })
    expect(retried.isEmpty && regular.allSatisfy { $0.writes == [true, false] },
           "later positive already-visible read removes uncertain intent without repeating successful restores")
}
for unknownKind in ["app-timeout", "missing-role", "sheet"] {
    let access = FakeAccess(), window = FakeWindow(), front = FakeWindow()
    access.applications[100] = [window]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target(), target(101)])
    access.applications[101] = [front]
    if unknownKind == "app-timeout" { access.failures[101] = .cannotComplete }
    if unknownKind == "missing-role" { front.role = nil }
    if unknownKind == "sheet" { front.subrole = kAXDialogSubrole }
    let result = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101)
    expect(!result.reset && result.saved.count == 1,
           "unrelated foreground \(unknownKind) preserves actual recovery batch")
    let (restored, pending, _) = engine(access).restore(result.saved, cancelled: { false })
    expect(restored == 1 && pending.isEmpty && !window.minimized,
           "unrelated foreground \(unknownKind) cannot veto normal window restoration")
}
do {
    let access = FakeAccess(), readable = FakeWindow(), closed = FakeWindow(), unreadable = FakeWindow()
    readable.minimized = true; closed.readError = .invalidUIElement
    unreadable.minimized = true; unreadable.readError = .cannotComplete
    let saved = [closed, unreadable, readable].map { EngineSaved(pid: 100, application: "测试", element: $0, confirmedMinimized: true) }
    let (count, pending, _) = engine(access).restore(saved, cancelled: { false })
    expect(count == 1 && !readable.minimized, "closed and unavailable targets before a healthy target do not stop restoration")
    expect(pending.count == 1 && pending[0].element === unreadable,
           "closed target is removed while temporarily unreadable target remains recoverable")
    expect(closed.writes.isEmpty && unreadable.writes.isEmpty,
           "restore never writes to known closed or unreadable target")
}

// Non-minimized does not mean visible: apps may expose inactive internal
// windows and windows on another Space in AXWindows.
do {
    let access = FakeAccess(), first = FakeWindow(), internalWindow = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    internalWindow.onScreen = false; access.applications[100]?.append(internalWindow)
    let hidden = inspector(access).inspect(baseline, targets: [target()])
    expect(!hidden.reset && hidden.saved.count == 1, "new non-minimized offscreen/internal AX window does not clear recovery")
    expect(!inspector(access).inspect(hidden.baseline, targets: [target()]).reset,
           "repeated reads of offscreen window never turn activation into a batch reset")
    internalWindow.onScreen = true
    expect(inspector(access).inspect(hidden.baseline, targets: [target()]).reset,
           "previously offscreen ordinary window becoming truly onscreen counts as new visible work")
}
do {
    let access = FakeAccess(), first = FakeWindow(), second = FakeWindow()
    access.applications[100] = [first, second]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    first.minimized = false; first.onScreen = false
    let offscreen = inspector(access).inspect(baseline, targets: [target()])
    expect(!offscreen.reset && offscreen.saved.count == 2,
           "saved window non-minimized on another Space is not proof of user expansion")
    first.onScreen = true
    expect(inspector(access).inspect(offscreen.baseline, targets: [target()]).reset,
           "confirmed saved window truly visible after expansion still resets the batch")
}
do {
    let access = FakeAccess(), first = FakeWindow(), unknown = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    unknown.onScreenError = .cannotComplete;access.applications[101] = [unknown]
    let unreadable = inspector(access).inspect(baseline, targets: [target(), target(101)], criticalPID: 101)
    expect(!unreadable.reset && unreadable.saved.count == 1 && unreadable.incomplete,
           "missing CG/AX geometry information is unknown rather than visible work")
    let (restored, pending, _) = engine(access).restore(unreadable.saved, cancelled: { false })
    expect(restored == 1 && pending.isEmpty,
           "visibility detector failure cannot block normal saved-window restoration")
}
do {
    let access = FakeAccess(), first = FakeWindow(), hiddenNew = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    let baseline = inspector(access).capture(saved: saved, targets: [target()])
    hiddenNew.onScreen = false;access.applications[101] = [hiddenNew]
    let newProcess = inspector(access).inspect(baseline, targets: [target(), target(101)])
    expect(!newProcess.reset, "new app process without an actual onscreen window cannot clear recovery")
    hiddenNew.onScreen = true
    expect(inspector(access).inspect(newProcess.baseline, targets: [target(), target(101)]).reset,
           "new app visible window is detected when it actually appears onscreen")
}
do {
    let frame = CGRect(x: 100, y: 200, width: 600, height: 400)
    let surface = OnScreenWindowGeometry(pid: 100, layer: 0, alpha: 1, frame: frame)
    expect(surface.matches(pid: 100, frame: frame), "same owner and exact top-left geometry identifies onscreen ordinary window")
    expect(surface.matches(pid: 100, frame: CGRect(x: 102, y: 198, width: 602, height: 398)),
           "two point geometry tolerance covers rounding")
    expect(!surface.matches(pid: 101, frame: frame), "same rectangle in another app is never a visible match")
    expect(!surface.matches(pid: 100, frame: CGRect(x: 100, y: 203, width: 600, height: 400)),
           "nearby but different window frame is not an onscreen match")
    expect(!OnScreenWindowGeometry(pid: 100, layer: 3, alpha: 1, frame: frame).matches(pid: 100, frame: frame),
           "raised overlay surface does not prove ordinary window visibility")
    expect(!OnScreenWindowGeometry(pid: 100, layer: 0, alpha: 0, frame: frame).matches(pid: 100, frame: frame),
           "fully transparent surface is not visible work")
}

// AX success can precede the on-screen animation. Keep provenance even for
// successful targets no longer in pending, until their first visible readback.
do {
    let access = FakeAccess(), successful = FakeWindow(), failed = FakeWindow()
    access.applications[100] = [successful, failed]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    successful.onScreen = false
    failed.applyWrite = false; failed.writeError = .notImplemented
    var accepted: [EngineSaved<FakeWindow>] = []
    let (restored, pending, _) = engine(access).restore(saved, cancelled: { false }, onRestoreAccepted: { accepted.append($0) })
    expect(restored == 1 && pending.count == 1 && pending[0].element === failed,
           "successful AX restore is removed from pending even while its window animation remains offscreen")
    expect(accepted.count == 1 && accepted[0].element === successful && accepted[0].restoreRequested,
           "accepted restore callback records successful window and excludes rejected request")
    let baseline = inspector(access).capture(saved: pending, targets: [target()], ownRestores: accepted)
    expect(baseline.ownRestores.count == 1 && baseline.ownRestores[0].element === successful,
           "capture retains accepted provenance independently of pending recovery list")
    let notVisibleYet = inspector(access).inspect(baseline, targets: [target()])
    expect(!notVisibleYet.reset && notVisibleYet.saved.count == 1 && notVisibleYet.baseline.ownRestores.count == 1,
           "offscreen animation preserves remaining failed window and provenance")
    successful.onScreen = true
    let visible = inspector(access).inspect(notVisibleYet.baseline, targets: [target()])
    expect(!visible.reset && visible.saved.count == 1 && visible.saved[0].element === failed,
           "own successful window appearing onscreen does not clear unrelated pending recovery")
    expect(visible.baseline.ownRestores.isEmpty,
           "first on-screen confirmation consumes accepted restore provenance")
    expect(!inspector(access).inspect(visible.baseline, targets: [target()]).reset,
           "own completed animation remains a neutral baseline on later polls")
    access.applications[100]?.append(FakeWindow())
    expect(inspector(access).inspect(visible.baseline, targets: [target()]).reset,
           "consumed restore provenance does not suppress later genuinely new windows")
}
do {
    let access = FakeAccess(), first = FakeWindow()
    access.applications[100] = [first]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    var accepted: [EngineSaved<FakeWindow>] = []
    let (_, pending, _) = engine(access).restore(saved, cancelled: { false }, onRestoreAccepted: { accepted.append($0) })
    expect(pending.isEmpty && accepted.count == 1,
           "callback includes accepted restore when the whole operation succeeds")
    expect(inspector(access).capture(saved: pending, targets: [target()], ownRestores: accepted).ownRestores.isEmpty,
           "already on-screen accepted restore does not retain unnecessary provenance")
}
do {
    let access = FakeAccess(), first = FakeWindow(), other = FakeWindow()
    access.applications[100] = [first, other]
    let (_, saved) = engine(access).minimize([target()], cancelled: { false })
    first.onScreen = false;other.applyWrite = false;other.writeError = .notImplemented
    var accepted: [EngineSaved<FakeWindow>] = []
    let (_, pending, _) = engine(access).restore(saved, cancelled: { false }, onRestoreAccepted: { accepted.append($0) })
    let baseline = inspector(access).capture(saved: pending, targets: [target()], ownRestores: accepted)
    // A retry must carry the outstanding list into its new capture, as AppModel
    // does, even if this attempt sends no new accepted requests for that window.
    let (_, retryPending, _) = engine(access).restore(pending, cancelled: { false })
    let recaptured = inspector(access).capture(saved: retryPending, targets: [target()], ownRestores: baseline.ownRestores)
    first.onScreen = true
    expect(!inspector(access).inspect(recaptured, targets: [target()]).reset,
           "outstanding successful animation provenance survives a retry and recapture")
}

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
print("PASS: \(checks) assertions; partial-batch recovery, uncertainty isolation, state reset and preserved features.")
