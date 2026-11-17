import AppKit
import ApplicationServices

struct WindowTarget {
    let pid: pid_t
    let name: String
    var isHidden = false
}

enum WindowToggleAction {
    case minimize, restore
}

enum MinimizeMode: String, CaseIterable {
    case sequential, simultaneous
    static let settingsKey = "minimizeMode.v1"
    static func load(from defaults: UserDefaults) -> MinimizeMode {
        defaults.string(forKey: settingsKey).flatMap(Self.init(rawValue:)) ?? .simultaneous
    }
    func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.settingsKey) }
    var title: String { self == .sequential ? "顺序收起" : "同时收起" }
}

// One recovery batch only. Starting a new minimize operation replaces the batch;
// a partial restore keeps only the unresolved windows from that same operation.
struct LastWindowBatch<Element> {
    private(set) var windows: [Element] = []
    var nextAction: WindowToggleAction { windows.isEmpty ? .minimize : .restore }
    mutating func replace(with windows: [Element]) { self.windows = windows }
    mutating func finishRestore(pending: [Element]) { windows = pending }
}

struct WindowReport {
    var succeeded = 0
    var already = 0
    var skipped = 0
    var failed = 0
    var details: [String] = []
    var interrupted = false

    mutating func detail(_ message: String) { if details.count < 80 { details.append(message) } }
    var summary: String {
        var parts = ["已最小化 \(succeeded) 个窗口"]
        if already > 0 { parts.append("原已最小化 \(already) 个") }
        if skipped > 0 { parts.append("跳过 \(skipped) 个") }
        if failed > 0 { parts.append("\(failed) 项未完成") }
        if interrupted { parts.append("达到时间上限，部分应用未处理") }
        return parts.joined(separator: "，") + "。"
    }
}

enum AccessResult<Value> {
    case success(Value)
    case failure(AXError)
}

protocol WindowAccess {
    associatedtype Element
    func windows(pid: pid_t) -> AccessResult<[Element]>
    func bool(_ element: Element, _ attribute: String) -> AccessResult<Bool>
    func string(_ element: Element, _ attribute: String) -> String?
    func canWriteMinimized(_ element: Element) -> Bool
    func setMinimized(_ element: Element, _ minimized: Bool) -> AXError
    func same(_ lhs: Element, _ rhs: Element) -> Bool
    func isOnScreen(_ element: Element, pid: pid_t) -> AccessResult<Bool>
}

// Matching uses public geometry and ownership metadata only. Window names and
// image pixels are never requested, so detection requires no screen capture access.
struct OnScreenWindowGeometry {
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let frame: CGRect
    func matches(pid: pid_t, frame: CGRect) -> Bool {
        self.pid == pid && layer == 0 && alpha > 0.01 && self.frame.width > 0 && self.frame.height > 0 &&
        abs(self.frame.minX - frame.minX) <= 2 && abs(self.frame.minY - frame.minY) <= 2 &&
        abs(self.frame.width - frame.width) <= 2 && abs(self.frame.height - frame.height) <= 2
    }
}

struct AXWindowAccess: WindowAccess {
    var messagingTimeout: Float
    private let onScreenWindows: [OnScreenWindowGeometry]?
    init(messagingTimeout: Float = 0.4) {
        self.messagingTimeout = messagingTimeout
        // One CG snapshot per access instance / inspection, never one per window.
        if let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            onScreenWindows = rows.compactMap { row in
                guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                return OnScreenWindowGeometry(pid: owner.int32Value,
                    layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                    alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                    frame: frame)
            }
        } else { onScreenWindows = nil }
    }
    func windows(pid: pid_t) -> AccessResult<[AXUIElement]> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let elements = value as? [AXUIElement] else { return .failure(.illegalArgument) }
        for element in elements { AXUIElementSetMessagingTimeout(element, messagingTimeout) }
        return .success(elements)
    }
    func bool(_ element: AXUIElement, _ attribute: String) -> AccessResult<Bool> {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let number = value as? NSNumber else { return .failure(.illegalArgument) }
        return .success(number.boolValue)
    }
    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    func canWriteMinimized(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) == .success && settable.boolValue
    }
    func setMinimized(_ element: AXUIElement, _ minimized: Bool) -> AXError {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }
    func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
    func isOnScreen(_ element: AXUIElement, pid: pid_t) -> AccessResult<Bool> {
        guard let rows = onScreenWindows else { return .failure(.cannotComplete) }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        func attribute(_ key: String) -> AccessResult<AXValue> {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            guard error == .success else { return .failure(error) }
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.illegalArgument) }
            return .success(unsafeBitCast(value, to: AXValue.self))
        }
        var position = CGPoint.zero, size = CGSize.zero
        switch attribute(kAXPositionAttribute) {
        case .success(let value):
            guard AXValueGetValue(value, .cgPoint, &position) else { return .failure(.illegalArgument) }
        case .failure(let error): return .failure(error)
        }
        switch attribute(kAXSizeAttribute) {
        case .success(let value):
            guard AXValueGetValue(value, .cgSize, &size) else { return .failure(.illegalArgument) }
        case .failure(let error): return .failure(error)
        }
        // AX and CGWindow bounds both use global top-left coordinates.
        let frame = CGRect(origin: position, size: size)
        return .success(rows.contains { $0.matches(pid: pid, frame: frame) })
    }
}

struct EngineSaved<Element> {
    let pid: pid_t
    let application: String
    let element: Element
    // An accepted write can time out before confirmation. Such an intent is still
    // recoverable, but cannot prove a later visible window was manually expanded.
    var confirmedMinimized: Bool = false
    // An accepted restore may finish after the shared verification timeout.
    var restoreRequested = false
}

struct RecoveryApplication<Element> {
    let pid: pid_t
    let windows: [Element]
    let visible: [Element]
    let minimized: [Element]
    var isHidden = false
    var unknownStates: [Element] = []
    var offscreen: [Element] = []
}

struct RecoveryBaseline<Element> {
    var applications: [RecoveryApplication<Element>] = []
    // Includes unsuccessful/unqueried apps, so their first successful read does
    // not look like a newly launched app or a new window.
    var knownPIDs: Set<pid_t> = []
    var saved: [EngineSaved<Element>] = []
    var pendingNewPIDs: Set<pid_t> = []
    // Accepted restores can leave `saved` as soon as AXMinimized becomes false,
    // before their animation produces a matching on-screen CG window.
    var ownRestores: [EngineSaved<Element>] = []
}

struct RecoveryInspection<Element> {
    let baseline: RecoveryBaseline<Element>
    let reset: Bool
    let incomplete: Bool
    // Diagnostic only. Unknown information must never veto the whole batch:
    // WindowEngine.restore rechecks each saved target and retains only failures.
    let criticalUnknown: Bool
    var saved: [EngineSaved<Element>] { reset ? [] : baseline.saved }
}

// Read-only observation is intentionally separate from minimize/restore writes.
// Call capture after a batch settles, then inspect while waiting and immediately
// before a toggle. A query failure is unknown, never a user-expansion signal.
struct RecoveryInspector<Access: WindowAccess> {
    let access: Access
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var globalBudget: TimeInterval = 1.5

    private struct Observation {
        var applications: [RecoveryApplication<Access.Element>] = []
        var incomplete = false
    }

    private func observe(_ targets: [WindowTarget], cancelled: () -> Bool) -> Observation {
        var result = Observation()
        let deadline = now() + globalBudget
        for target in targets {
            guard !cancelled(), now() < deadline else { result.incomplete = true; break }
            let windows: [Access.Element]
            switch access.windows(pid: target.pid) {
            case .success(let values): windows = values
            case .failure: result.incomplete = true; continue
            }
            var visible: [Access.Element] = [], minimized: [Access.Element] = [], unknown: [Access.Element] = [], offscreen: [Access.Element] = []
            for (index, element) in windows.enumerated() {
                guard !cancelled(), now() < deadline else {
                    result.incomplete = true; unknown.append(contentsOf: windows[index...]); break
                }
                // A missing role is unknown, not evidence of an auxiliary layer.
                guard let role = access.string(element, kAXRoleAttribute) else {
                    result.incomplete = true; unknown.append(element); continue
                }
                guard role == kAXWindowRole else { continue }
                guard let subrole = access.string(element, kAXSubroleAttribute) else {
                    result.incomplete = true; unknown.append(element); continue
                }
                guard subrole == kAXStandardWindowSubrole else { continue }
                switch access.bool(element, "AXFullScreen") {
                case .success(true): continue
                case .failure(let error) where error != .attributeUnsupported && error != .noValue:
                    result.incomplete = true; unknown.append(element); continue
                default: break
                }
                switch access.bool(element, kAXMinimizedAttribute) {
                case .success(true): minimized.append(element)
                case .success(false):
                    if target.isHidden { offscreen.append(element); continue }
                    // AXMinimized=false also describes internal/inactive windows
                    // and windows on other Spaces. Require actual CG visibility.
                    switch access.isOnScreen(element, pid: target.pid) {
                    case .success(true): visible.append(element)
                    case .success(false): offscreen.append(element)
                    case .failure: result.incomplete = true; unknown.append(element)
                    }
                case .failure: result.incomplete = true; unknown.append(element)
                }
            }
            result.applications.append(RecoveryApplication(pid: target.pid, windows: windows,
                visible: visible, minimized: minimized, isHidden: target.isHidden, unknownStates: unknown, offscreen: offscreen))
        }
        return result
    }

    func capture(saved: [EngineSaved<Access.Element>], targets: [WindowTarget],
                 ownRestores: [EngineSaved<Access.Element>] = [],
                 cancelled: () -> Bool = { false }) -> RecoveryBaseline<Access.Element> {
        let observed = observe(targets, cancelled: cancelled)
        var baseline = RecoveryBaseline(applications: observed.applications,
                                        knownPIDs: Set(targets.map(\.pid)), saved: saved)
        for item in ownRestores + saved.filter(\.restoreRequested) {
            let visible = observed.applications.contains { app in
                app.pid == item.pid && app.visible.contains { access.same($0, item.element) }
            }
            if !visible && !baseline.ownRestores.contains(where: { $0.pid == item.pid && access.same($0.element, item.element) }) {
                baseline.ownRestores.append(item)
            }
        }
        // Promote delayed writes only after positive minimized readback.
        for index in baseline.saved.indices {
            let item = baseline.saved[index]
            if observed.applications.contains(where: { $0.pid == item.pid && $0.minimized.contains(where: { access.same($0, item.element) }) }) {
                baseline.saved[index].confirmedMinimized = true
            }
        }
        return baseline
    }

    func inspect(_ baseline: RecoveryBaseline<Access.Element>, targets: [WindowTarget],
                 criticalPID: pid_t? = nil, cancelled: () -> Bool = { false }) -> RecoveryInspection<Access.Element> {
        let observed = observe(targets, cancelled: cancelled)
        let running = Set(targets.map(\.pid))
        var updated = baseline
        updated.pendingNewPIDs.formUnion(running.subtracting(baseline.knownPIDs))
        updated.pendingNewPIDs.formIntersection(running)
        var reset = false
        var criticalUnknown = false
        func ownRestore(_ pid: pid_t, _ window: Access.Element) -> Bool {
            baseline.ownRestores.contains { $0.pid == pid && access.same($0.element, window) } ||
                baseline.saved.contains { $0.pid == pid && $0.restoreRequested && access.same($0.element, window) }
        }
        // Only an absent process or a successful complete AXWindows list proves
        // closure. Permission/timeouts preserve recovery intent for another try.
        updated.saved.removeAll { item in
            guard running.contains(item.pid) else { return true }
            guard let app = observed.applications.first(where: { $0.pid == item.pid }) else { return false }
            return !app.windows.contains(where: { access.same($0, item.element) }) ||
                (item.restoreRequested && app.visible.contains(where: { access.same($0, item.element) }))
        }
        for index in updated.saved.indices {
            let item = updated.saved[index]
            guard let app = observed.applications.first(where: { $0.pid == item.pid }) else {
                criticalUnknown = true; continue
            }
            if !app.minimized.contains(where: { access.same($0, item.element) }) &&
                !app.visible.contains(where: { access.same($0, item.element) }) { criticalUnknown = true }
            if !item.restoreRequested && item.confirmedMinimized && app.visible.contains(where: { access.same($0, item.element) }) { reset = true }
            if app.minimized.contains(where: { access.same($0, item.element) }) {
                updated.saved[index].confirmedMinimized = true
            }
        }
        if let criticalPID, running.contains(criticalPID) {
            if let app = observed.applications.first(where: { $0.pid == criticalPID }) {
                if !app.unknownStates.isEmpty { criticalUnknown = true }
            } else { criticalUnknown = true }
        }
        for app in observed.applications {
            let manualVisible = app.visible.filter { !ownRestore(app.pid, $0) }
            if updated.pendingNewPIDs.contains(app.pid) && !manualVisible.isEmpty { reset = true }
            if let previous = baseline.applications.first(where: { $0.pid == app.pid }) {
                if previous.isHidden && !app.isHidden && !manualVisible.isEmpty { reset = true }
                for window in manualVisible {
                    // An unchanged pre-existing visible window (e.g. unsupported
                    // minimize) must not immediately invalidate the fresh batch.
                    let wasVisible = previous.visible.contains(where: { access.same($0, window) })
                    let wasMinimized = previous.minimized.contains(where: { access.same($0, window) })
                    let wasOffscreen = previous.offscreen.contains(where: { access.same($0, window) })
                    let existed = previous.windows.contains(where: { access.same($0, window) })
                    if !wasVisible && (wasMinimized || wasOffscreen || !existed) { reset = true }
                }
            }
            // Establish a baseline after previously unavailable apps become
            // readable, rather than treating their old windows as newly opened.
            if let index = updated.applications.firstIndex(where: { $0.pid == app.pid }) {
                var previous = updated.applications[index]
                // Once our late restore completes, its visible state becomes the
                // neutral baseline too; the next poll must not rediscover it as manual.
                let completedOwn = app.visible.filter { window in ownRestore(app.pid, window) &&
                    !previous.visible.contains(where: { access.same($0, window) }) }
                if !completedOwn.isEmpty {
                    previous = RecoveryApplication(pid: app.pid, windows: previous.windows,
                        visible: previous.visible + completedOwn, minimized: previous.minimized,
                        isHidden: app.isHidden, offscreen: previous.offscreen)
                }
                // Keep known visible windows plus newly readable unknown windows;
                // retain minimized history to detect a later expansion.
                for window in app.windows where !previous.windows.contains(where: { access.same($0, window) }) {
                    previous = RecoveryApplication(pid: app.pid, windows: previous.windows + [window],
                        visible: previous.visible + app.visible.filter { access.same($0, window) },
                        minimized: previous.minimized + app.minimized.filter { access.same($0, window) }, isHidden: app.isHidden,
                        offscreen: previous.offscreen + app.offscreen.filter { access.same($0, window) })
                }
                // Unknown state now readable needs a neutral initial baseline.
                for window in app.visible + app.minimized + app.offscreen where
                    !previous.visible.contains(where: { access.same($0, window) }) &&
                    !previous.minimized.contains(where: { access.same($0, window) }) &&
                    !previous.offscreen.contains(where: { access.same($0, window) }) {
                    previous = RecoveryApplication(pid: app.pid, windows: previous.windows,
                        visible: previous.visible + app.visible.filter { access.same($0, window) },
                        minimized: previous.minimized + app.minimized.filter { access.same($0, window) }, isHidden: app.isHidden,
                        offscreen: previous.offscreen + app.offscreen.filter { access.same($0, window) })
                }
                previous.isHidden = app.isHidden
                updated.applications[index] = previous
            } else { updated.applications.append(app) }
        }
        // Consume provenance only after its first on-screen readback (or known
        // closure/exit). The neutral visible baseline above then prevents repeats.
        updated.ownRestores.removeAll { item in
            guard running.contains(item.pid) else { return true }
            guard let app = observed.applications.first(where: { $0.pid == item.pid }) else { return false }
            return !app.windows.contains(where: { access.same($0, item.element) }) ||
                app.visible.contains(where: { access.same($0, item.element) })
        }
        updated.knownPIDs.formUnion(observed.applications.map(\.pid))
        if reset { updated.saved = []; updated.ownRestores = [] }
        return RecoveryInspection(baseline: updated, reset: reset, incomplete: observed.incomplete,
                                  criticalUnknown: criticalUnknown)
    }
}

// Kept separate from AppKit so timeout, exclusion and recovery behavior are testable.
struct WindowEngine<Access: WindowAccess> {
    let access: Access
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var globalBudget: TimeInterval = 25
    var applicationBudget: TimeInterval = 5

    private struct Request {
        let snapshot: EngineSaved<Access.Element>
        let result: AXError
    }

    // All accepted writes are issued before any animation polling or sleeping.
    // One shared verification window prevents N windows from costing N animation waits.
    private func verify(_ requests: [Request], minimized: Bool, deadline: TimeInterval,
                        cancelled: () -> Bool) -> Set<Int> {
        var confirmed: Set<Int> = []
        let settleDeadline = min(deadline, now() + 1.2)
        for round in 0..<11 {
            if round > 0 {
                guard !cancelled(), now() < settleDeadline else { break }
                pause(min(0.12, max(0, settleDeadline - now())))
            }
            for index in requests.indices where !confirmed.contains(index) {
                guard now() < deadline else { return confirmed }
                if case .success(let value) = access.bool(requests[index].snapshot.element, kAXMinimizedAttribute),
                   value == minimized { confirmed.insert(index) }
            }
            if confirmed.count == requests.count || requests.isEmpty { break }
        }
        return confirmed
    }

    func minimize(_ targets: [WindowTarget], mode: MinimizeMode = .simultaneous, cancelled: () -> Bool,
                  onRequestsDispatched: () -> Void = {}) -> (WindowReport, [EngineSaved<Access.Element>]) {
        var report = WindowReport()
        var candidates: [EngineSaved<Access.Element>] = []
        let start = now()
        let deadline = start + globalBudget
        // Snapshot and validate all candidate windows before starting the burst.
        for target in targets {
            guard !cancelled(), now() < deadline else { report.interrupted = true; break }
            let appStart = now()
            let windows: [Access.Element]
            switch access.windows(pid: target.pid) {
            case .failure(let error):
                report.failed += 1
                report.detail("\(target.name)：无法读取窗口（\(error.rawValue)）。")
                continue
            case .success(let values): windows = values
            }
            for element in windows {
                guard !cancelled(), now() < deadline else { report.interrupted = true; break }
                guard now() - appStart < applicationBudget else {
                    report.failed += 1; report.detail("\(target.name)：响应较慢，余下窗口未处理。"); break
                }
                guard access.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else {
                    report.skipped += 1; report.detail("\(target.name)：跳过非普通窗口。"); continue
                }
                switch access.bool(element, kAXMinimizedAttribute) {
                case .success(true): report.already += 1; continue
                case .failure(let error): report.failed += 1; report.detail("\(target.name)：无法读取最小化状态（\(error.rawValue)）。"); continue
                case .success(false): break
                }
                switch access.bool(element, "AXFullScreen") {
                case .success(true): report.skipped += 1; report.detail("\(target.name)：跳过全屏窗口。"); continue
                case .failure(let error) where error != .attributeUnsupported && error != .noValue:
                    report.failed += 1; report.detail("\(target.name)：无法确认全屏状态（\(error.rawValue)），跳过此窗口。"); continue
                default: break
                }
                guard access.canWriteMinimized(element) else {
                    report.skipped += 1; report.detail("\(target.name)：窗口不支持最小化。"); continue
                }
                if !candidates.contains(where: { $0.pid == target.pid && access.same($0.element, element) }) {
                    candidates.append(EngineSaved(pid: target.pid, application: target.name, element: element))
                }
            }
        }
        var issued: [Request] = []
        var confirmed: Set<Int> = []
        // Sequential waits for each window; simultaneous sends the entire burst first.
        for candidate in candidates {
            guard !cancelled(), now() < deadline else { report.interrupted = true; break }
            let result = access.setMinimized(candidate.element, true)
            let request = Request(snapshot: candidate, result: result)
            issued.append(request)
            if mode == .sequential,
               verify([request], minimized: true, deadline: deadline, cancelled: cancelled).contains(0) {
                confirmed.insert(issued.count - 1)
            }
        }
        if !cancelled(), now() < deadline { onRequestsDispatched() }
        if mode == .simultaneous {
            confirmed = verify(issued, minimized: true, deadline: deadline, cancelled: cancelled)
        }
        var saved: [EngineSaved<Access.Element>] = []
        for (index, request) in issued.enumerated() {
            if confirmed.contains(index) {
                report.succeeded += 1
                var snapshot = request.snapshot
                snapshot.confirmedMinimized = true
                saved.append(snapshot)
            } else {
                report.failed += 1
                report.detail("\(request.snapshot.application)：未能确认窗口已最小化（\(request.result.rawValue)），可重试恢复。")
                // A timed-out write can still be accepted; retain only this operation's intent.
                if request.result == .success || request.result == .cannotComplete { saved.append(request.snapshot) }
            }
        }
        if cancelled() || now() >= deadline { report.interrupted = true }
        return (report, saved)
    }

    func restore(_ saved: [EngineSaved<Access.Element>], cancelled: () -> Bool,
                 onRequestsDispatched: () -> Void = {},
                 onRestoreAccepted: (EngineSaved<Access.Element>) -> Void = { _ in }) -> (Int, [EngineSaved<Access.Element>], [String]) {
        var pending: [EngineSaved<Access.Element>] = []
        var details: [String] = []
        var candidates: [EngineSaved<Access.Element>] = []
        let deadline = now() + globalBudget
        for (index, snapshot) in saved.enumerated() {
            guard !cancelled(), now() < deadline else {
                pending.append(contentsOf: saved[index...]); details.append("操作停止或达到时间上限，仍有窗口待恢复。"); break
            }
            switch access.bool(snapshot.element, kAXMinimizedAttribute) {
            case .success(false): continue
            case .failure(.invalidUIElement): continue
            case .failure(let error):
                pending.append(snapshot); details.append("\(snapshot.application)：暂时无法读取窗口（\(error.rawValue)）。"); continue
            case .success(true): candidates.append(snapshot)
            }
        }
        var issued: [Request] = []
        for (index, candidate) in candidates.enumerated() {
            guard !cancelled(), now() < deadline else {
                pending.append(contentsOf: candidates[index...]); break
            }
            let result = access.setMinimized(candidate.element, false)
            var requested = candidate
            if result == .success || result == .cannotComplete {
                requested.restoreRequested = true
                onRestoreAccepted(requested)
            }
            issued.append(Request(snapshot: requested, result: result))
        }
        if !cancelled(), now() < deadline { onRequestsDispatched() }
        let confirmed = verify(issued, minimized: false, deadline: deadline, cancelled: cancelled)
        for (index, request) in issued.enumerated() where !confirmed.contains(index) {
            pending.append(request.snapshot)
            details.append("\(request.snapshot.application)：恢复未确认（\(request.result.rawValue)），可以重试。")
        }
        return (confirmed.count, pending, Array(details.prefix(80)))
    }

}

final class CancellationFlag {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
