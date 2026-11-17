import AppKit
import ApplicationServices
import Carbon

// One physical key press chooses exactly one action. A native Escape is terminal,
// as is an AX close/cancel request, including errors and save-confirmation sheets.
struct EscapeTransaction {
    enum Route { case native, close }
    enum State: Equatable { case pending, native, close, cancelled }
    private(set) var state: State = .pending
    mutating func resolve(_ route: Route) -> Bool {
        guard state == .pending else { return false }
        state = route == .native ? .native : .close
        return true
    }
    mutating func cancel() { if state == .pending { state = .cancelled } }
}

enum EscapeLayerKind { case window, overlay, content }
enum EscapeAction { case closeButton, cancelButton, cancel }
struct EscapeLayer<Element> {
    let element: Element
    let kind: EscapeLayerKind
    let close: Element?
    let cancel: Element?
    let supportsCancel: Bool
}
struct EscapeSelection<Element> {
    let layer: Element
    let control: Element
    let action: EscapeAction
}
struct EscapeSelectionPolicy {
    static let actionTimeout: Float = 2
    static func blocksForForeignWindow(layer: Int, width: Double, height: Double, systemAuxiliary: Bool = false) -> Bool {
        // A background VM/ordinary app isn't a screenshot overlay. Compact input
        // candidates remain native cancellation targets; large raised layers are
        // screenshot/selection/panel candidates.
        !systemAuxiliary && layer > 0 && width > 60 && height > 40
    }
    static func isCancelControl(identifier: String?, title: String?, role: String?, enabled: Bool) -> Bool {
        guard enabled, role == kAXButtonRole else { return false }
        return identifier == "CancelButton" || identifier == "cancel" || ["Cancel", "取消"].contains(title ?? "")
    }
    // Layers arrive topmost first. Never fall through a nonclosable top layer.
    static func select<Element>(_ layers: [EscapeLayer<Element>]) -> EscapeSelection<Element>? {
        guard let top = layers.first else { return nil }
        switch top.kind {
        case .content: return nil // Internal page/tab is not a top-level close target.
        case .overlay:
            if let button = top.close { return EscapeSelection(layer: top.element, control: button, action: .closeButton) }
            if let button = top.cancel { return EscapeSelection(layer: top.element, control: button, action: .cancelButton) }
            if top.supportsCancel { return EscapeSelection(layer: top.element, control: top.element, action: .cancel) }
            return nil
        case .window:
            guard let button = top.close else { return nil }
            return EscapeSelection(layer: top.element, control: button, action: .closeButton)
        }
    }
    static func mayCloseSameTarget(sameRoot: Bool, sameLayer: Bool, sameControl: Bool, cancelled: Bool) -> Bool {
        sameRoot && sameLayer && sameControl && !cancelled
    }
    static func mayForwardUnknown(isRecognizedOverlay: Bool) -> Bool {
        // Missing ordinary-window information must not be turned into a native
        // Escape which an app might interpret as "close internal tab".
        isRecognizedOverlay
    }
}

// Unsupported is distinct from a failed AX request: apps without the optional
// attribute keep working, while a timeout must not authorize a destructive action.
enum EscapeFullScreenState { case windowed, fullScreen, unsupported, unavailable }
struct EscapeFullScreenPolicy {
    static func evaluate(_ states: [EscapeFullScreenState]) -> EscapeFullScreenState {
        if states.contains(.fullScreen) { return .fullScreen }
        if states.contains(.unavailable) || states.isEmpty { return .unavailable }
        return states.contains(.windowed) ? .windowed : .unsupported
    }
    static func permitsClose(_ state: EscapeFullScreenState) -> Bool {
        state == .windowed || state == .unsupported
    }
}

enum EscapeCloseError: LocalizedError {
    case permission, unavailable
    var errorDescription: String? {
        switch self {
        case .permission: return "ESC 关闭窗口需要辅助功能权限。请授权净桌后，再打开此开关。"
        case .unavailable: return "无法启用 ESC 控制，请检查辅助功能权限并重新打开净桌。"
        }
    }
}

final class EscapeCloseMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let queue = DispatchQueue(label: "local.jingzhuo.escape-close", qos: .userInitiated)
    private var suspended = false
    private var generation = 0
    private var current: Press?
    private var nativeHeld = false
    var onFailure: ((String) -> Void)?
    var onIssue: ((String) -> Void)?
    private struct Environment: Equatable {
        let windowIDs: [Int]
        let foreignOverlay: Bool
    }
    private struct Plan {
        let root: AXUIElement
        let selection: EscapeSelection<AXUIElement>
    }
    private enum Preparation {
        case ready(Plan), protectedFullScreen, unavailable
    }
    private final class Press {
        let pid: pid_t
        let epoch: Int
        let environment: Environment
        var released = false
        var complete = false
        var route = EscapeTransaction()
        let cancellation = CancellationFlag()
        init(pid: pid_t, epoch: Int, environment: Environment) {
            self.pid = pid; self.epoch = epoch; self.environment = environment
        }
    }

    func start() throws {
        precondition(Thread.isMainThread)
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { throw EscapeCloseError.permission }
        let events = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EscapeCloseMonitor>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw EscapeCloseError.unavailable }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); throw EscapeCloseError.unavailable
        }
        tap = port; source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value, let press = current {
            press.cancellation.cancel()
            if press.route.state == .pending { ignore(press, message: nil) }
        }
    }
    func stop() {
        if let press = current {
            press.cancellation.cancel()
            if press.route.state == .pending { ignore(press, message: nil) }
        }
        generation += 1
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; current = nil; nativeHeld = false
    }

    private func environment(_ pid: pid_t) -> Environment {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return Environment(windowIDs: [], foreignOverlay: true)
        }
        var ids: [Int] = [], ahead: [pid_t] = []
        let bundles = Dictionary(NSWorkspace.shared.runningApplications.map {
            ($0.processIdentifier, $0.bundleIdentifier ?? "")
        }, uniquingKeysWith: { first, _ in first })
        var found = false
        for row in rows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let id = row[kCGWindowNumber as String] as? NSNumber,
                  let rect = row[kCGWindowBounds as String] as? [String: Any],
                  let w = rect["Width"] as? NSNumber, let h = rect["Height"] as? NSNumber,
                  w.doubleValue > 60, h.doubleValue > 40,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { continue }
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0 else { continue }
            if owner.int32Value == pid { found = true; ids.append(id.intValue) }
            else if !found && EscapeSelectionPolicy.blocksForForeignWindow(layer: layer, width: w.doubleValue, height: h.doubleValue,
                systemAuxiliary: ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.windowmanager"].contains(bundles[owner.int32Value]?.lowercased() ?? "")) {
                ahead.append(owner.int32Value)
            }
        }
        return Environment(windowIDs: ids, foreignOverlay: !found || !ahead.isEmpty)
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(); onFailure?("ESC 控制已由系统暂停，请重新打开开关。")
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else { return Unmanaged.passUnretained(event) }
        if type == .keyUp {
            nativeHeld = false
            guard let press = current, !press.released else { return Unmanaged.passUnretained(event) }
            press.released = true
            switch press.route.state {
            case .pending: return nil
            case .native: clear(press); return Unmanaged.passUnretained(event)
            case .close, .cancelled:
                if press.complete { clear(press) }
                return nil
            }
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if let press = current {
            if press.route.state == .native, !press.released { return Unmanaged.passUnretained(event) }
            // Consume repeats / extra presses while a close is still completing,
            // rather than queue an action against a newly exposed lower window.
            return nil
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard !suspended, !nativeHeld, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.flags.intersection(modifiers).isEmpty, !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            nativeHeld = true; return Unmanaged.passUnretained(event)
        }
        let env = environment(pid)
        guard !env.foreignOverlay else {
            nativeHeld = true; return Unmanaged.passUnretained(event)
        }
        let press = Press(pid: pid, epoch: generation, environment: env)
        current = press
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, press.route.state == .pending else { return }
            press.cancellation.cancel()
            self.ignore(press, message: "窗口检查超时，本次 ESC 未执行关闭。请稍后重试。")
        }
        queue.async { [weak self] in
            guard let self else { return }
            let plan = self.prepare(pid: pid, visibleCount: env.windowIDs.count)
            DispatchQueue.main.async {
                guard press.route.state == .pending else { return }
                guard press.epoch == self.generation, !press.cancellation.cancelled, !self.suspended,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.environment(pid) == env else {
                    self.ignore(press, message: nil); return
                }
                let chosen: Plan
                switch plan {
                case .protectedFullScreen:
                    // Consume this press without native replay, window close or alert.
                    self.ignore(press, message: nil); return
                case .unavailable:
                    self.ignore(press, message: "无法确认当前窗口状态或关闭控件，本次未关闭。")
                    return
                case .ready(let plan): chosen = plan
                }
                // Consume the single physical key BEFORE issuing exactly one normal
                // close/cancel. No native fallback is possible after this commitment.
                guard press.route.resolve(.close) else { return }
                self.queue.async {
                    let prepared = press.cancellation.cancelled ? Preparation.unavailable : self.prepare(pid: pid, visibleCount: env.windowIDs.count)
                    if case .ready(let currentPlan) = prepared,
                       EscapeSelectionPolicy.mayCloseSameTarget(sameRoot: CFEqual(chosen.root, currentPlan.root),
                           sameLayer: CFEqual(chosen.selection.layer, currentPlan.selection.layer),
                           sameControl: CFEqual(chosen.selection.control, currentPlan.selection.control),
                           cancelled: press.cancellation.cancelled) {
                        // Recheck immediately before the side effect, after overlay discovery.
                        let app = AXUIElementCreateApplication(pid)
                        let finalState = self.fullScreenState(currentPlan.root, app: app)
                        if EscapeFullScreenPolicy.permitsClose(finalState) {
                            // Normal close may synchronously present an app-owned save sheet.
                            AXUIElementSetMessagingTimeout(currentPlan.selection.control, EscapeSelectionPolicy.actionTimeout)
                            let actionResult = AXUIElementPerformAction(currentPlan.selection.control,
                                (currentPlan.selection.action == .cancel ? kAXCancelAction : kAXPressAction) as CFString)
                            if actionResult != .success && actionResult != .cannotComplete {
                                DispatchQueue.main.async { self.onIssue?("系统未能关闭当前窗口（\(actionResult.rawValue)）。") }
                            }
                        } else if finalState != .fullScreen {
                            DispatchQueue.main.async { self.onIssue?("无法确认当前窗口的全屏状态，本次未关闭。") }
                        }
                    } else if case .protectedFullScreen = prepared {
                        // Entering full screen between discovery and execution cancels silently.
                    } else if !press.cancellation.cancelled {
                        DispatchQueue.main.async { self.onIssue?("当前窗口状态或浮层已改变，本次 ESC 未执行关闭。") }
                    }
                    DispatchQueue.main.async {
                        press.complete = true
                        if press.released { self.clear(press) }
                    }
                }
            }
        }
        return nil
    }
    private func clear(_ press: Press) { if current === press { current = nil } }
    private func ignore(_ press: Press, message: String?) {
        guard press.route.state == .pending else { return }
        press.route.cancel(); press.complete = true
        if press.released { clear(press) }
        if let message { onIssue?(message) }
    }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private func element(_ parent: AXUIElement, _ key: String) -> AXUIElement? {
        guard let v = value(parent, key), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeBitCast(v, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(result, 0.04); return result
    }
    private func bool(_ element: AXUIElement, _ key: String) -> Bool? { (value(element, key) as? NSNumber)?.boolValue }
    private func kind(_ element: AXUIElement) -> EscapeLayerKind? {
        let role = value(element, kAXRoleAttribute) as? String ?? ""
        let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
        if [kAXSheetRole, "AXPopover", "AXDialog", kAXMenuRole].contains(role) || subrole == kAXDialogSubrole ||
            subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" { return .overlay }
        if role == kAXWindowRole && bool(element, kAXModalAttribute) == true { return .overlay }
        if role == kAXWindowRole { return .window }
        return nil
    }
    private func descriptor(_ element: AXUIElement, kind: EscapeLayerKind) -> EscapeLayer<AXUIElement> {
        func enabled(_ key: String) -> AXUIElement? {
            guard let button = self.element(element, key), bool(button, kAXEnabledAttribute) == true else { return nil }
            return button
        }
        var names: CFArray?
        let cancel = AXUIElementCopyActionNames(element, &names) == .success && (names as? [String])?.contains(kAXCancelAction) == true
        var cancelButton = enabled(kAXCancelButtonAttribute)
        // Standard save/open panels may expose Cancel as a child button rather
        // than AXCancelButton. Never inspect or choose Save/Discard/OK controls.
        if kind == .overlay && cancelButton == nil {
            var pending: [(AXUIElement, Int)] = [(element, 0)]
            var inspected = 0
            while !pending.isEmpty && inspected < 48 {
                let (item, depth) = pending.removeFirst()
                inspected += 1
                AXUIElementSetMessagingTimeout(item, 0.025)
                if EscapeSelectionPolicy.isCancelControl(identifier: value(item, kAXIdentifierAttribute) as? String,
                    title: value(item, kAXTitleAttribute) as? String, role: value(item, kAXRoleAttribute) as? String,
                    enabled: bool(item, kAXEnabledAttribute) == true) { cancelButton = item; break }
                let role = value(item, kAXRoleAttribute) as? String ?? ""
                if depth < 4 && ![kAXScrollAreaRole, kAXOutlineRole, kAXTableRole, kAXListRole].contains(role) {
                    for child in value(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] { pending.append((child, depth + 1)) }
                }
            }
        }
        return EscapeLayer(element: element, kind: kind, close: enabled(kAXCloseButtonAttribute),
                           cancel: cancelButton, supportsCancel: cancel)
    }
    private func fullScreenState(_ root: AXUIElement, app: AXUIElement) -> EscapeFullScreenState {
        var states: [EscapeFullScreenState] = []
        var seen: Set<CFHashCode> = []
        func inspect(_ window: AXUIElement) {
            guard seen.insert(CFHash(window)).inserted else { return }
            AXUIElementSetMessagingTimeout(window, 0.04)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &result)
            switch error {
            case .success:
                if let flag = result as? NSNumber { states.append(flag.boolValue ? .fullScreen : .windowed) }
                else { states.append(.unavailable) }
            case .attributeUnsupported, .noValue: states.append(.unsupported)
            default: states.append(.unavailable)
            }
        }
        inspect(root)
        // Sheets/panels can themselves report false while their owner is full screen.
        // Inspect explicit containing/parent windows, never arbitrary other app windows.
        if let owner = element(root, kAXWindowAttribute), !CFEqual(owner, root) { inspect(owner) }
        var cursor = element(root, kAXParentAttribute)
        for _ in 0..<12 {
            guard let item = cursor, !CFEqual(item, app), !seen.contains(CFHash(item)) else { break }
            if value(item, kAXRoleAttribute) as? String == kAXWindowRole { inspect(item) }
            else { seen.insert(CFHash(item)) }
            cursor = element(item, kAXParentAttribute)
        }
        // Floating panels often have only AXApplication as their parent. Its main
        // window is the owner context; ordinary windows never inspect another window.
        if kind(root) == .overlay, let main = element(app, kAXMainWindowAttribute), !CFEqual(main, root) { inspect(main) }
        return EscapeFullScreenPolicy.evaluate(states)
    }
    private func prepare(pid: pid_t, visibleCount: Int) -> Preparation {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.04)
        var root = element(app, kAXFocusedWindowAttribute)
        if root == nil { root = element(app, kAXMainWindowAttribute) }
        if root == nil, visibleCount == 1, let list = value(app, kAXWindowsAttribute) as? [AXUIElement] {
            let candidates = list.filter { window in
                AXUIElementSetMessagingTimeout(window, 0.04)
                return bool(window, kAXMinimizedAttribute) != true && kind(window) != nil
            }
            if candidates.count == 1 { root = candidates[0] }
        }
        guard let root, bool(root, kAXMinimizedAttribute) != true else { return .unavailable }
        let fullScreen = fullScreenState(root, app: app)
        if fullScreen == .fullScreen { return .protectedFullScreen }
        guard EscapeFullScreenPolicy.permitsClose(fullScreen) else { return .unavailable }
        // The root close control closes the whole window, regardless of its focused
        // child, tab selection, chat content, or webpage. Never search for tab buttons.
        var top: AXUIElement?
        if let focused = element(app, kAXFocusedUIElementAttribute) {
            var cursor: AXUIElement? = focused
            var seen: Set<CFHashCode> = []
            for _ in 0..<16 {
                guard let item = cursor, !CFEqual(item, root), seen.insert(CFHash(item)).inserted else { break }
                if kind(item) == .overlay { top = item; break }
                cursor = element(item, kAXParentAttribute)
            }
        }
        // Check semantic overlay containers, not an app's complete document tree.
        // Ordinary tabs/web areas/content are not treated as overlays or closed.
        let began = ProcessInfo.processInfo.systemUptime
        var inspected = 0
        var incomplete = false
        func findOverlay(_ item: AXUIElement, depth: Int) -> AXUIElement? {
            inspected += 1
            guard inspected <= 48, ProcessInfo.processInfo.systemUptime - began < 0.18 else { incomplete = true; return nil }
            AXUIElementSetMessagingTimeout(item, 0.025)
            if kind(item) == .overlay { return item }
            let role = value(item, kAXRoleAttribute) as? String ?? ""
            guard depth < 2, [kAXGroupRole, "AXLayoutArea", "AXSplitGroup"].contains(role) else { return nil }
            for child in value(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let result = findOverlay(child, depth: depth + 1) { return result }
                if incomplete { return nil }
            }
            return nil
        }
        if top == nil {
            for child in value(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let result = findOverlay(child, depth: 0) { top = result; break }
                if incomplete { return .unavailable }
            }
        }
        if let top {
            guard let selection = EscapeSelectionPolicy.select([descriptor(top, kind: .overlay)]) else { return .unavailable }
            return .ready(Plan(root: root, selection: selection))
        }
        guard let rootKind = kind(root), let selection = EscapeSelectionPolicy.select([descriptor(root, kind: rootKind)]) else { return .unavailable }
        return .ready(Plan(root: root, selection: selection))
    }
}
