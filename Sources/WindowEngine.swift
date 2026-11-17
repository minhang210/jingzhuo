import AppKit
import ApplicationServices

struct WindowTarget {
    let pid: pid_t
    let name: String
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
}

struct AXWindowAccess: WindowAccess {
    func windows(pid: pid_t) -> AccessResult<[AXUIElement]> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let elements = value as? [AXUIElement] else { return .failure(.illegalArgument) }
        for element in elements { AXUIElementSetMessagingTimeout(element, 0.4) }
        return .success(elements)
    }
    func bool(_ element: AXUIElement, _ attribute: String) -> AccessResult<Bool> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let number = value as? NSNumber else { return .failure(.illegalArgument) }
        return .success(number.boolValue)
    }
    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    func canWriteMinimized(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) == .success && settable.boolValue
    }
    func setMinimized(_ element: AXUIElement, _ minimized: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }
    func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
}

struct EngineSaved<Element> {
    let pid: pid_t
    let application: String
    let element: Element
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
                saved.append(request.snapshot)
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
                 onRequestsDispatched: () -> Void = {}) -> (Int, [EngineSaved<Access.Element>], [String]) {
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
            issued.append(Request(snapshot: candidate, result: result))
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
