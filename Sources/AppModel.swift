import AppKit
import SwiftUI
import ServiceManagement

private enum BatchWindow {
    case external(EngineSaved<AXUIElement>)
    case local(NSWindow)
}

final class AppModel: ObservableObject {
    @Published var shortcut: Shortcut = .standard
    @Published var shortcutReady = false
    @Published var isRecording = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var busy = false
    @Published var message = "准备就绪。快捷键可在其他应用中使用。"
    @Published var details: [String] = []
    @Published var isError = false
    @Published var recoverableCount = 0
    @Published var nextAction: WindowToggleAction = .minimize
    @Published private(set) var minimizeMode = MinimizeMode.load(from: .standard)
    @Published var loginEnabled = false
    @Published var loginApprovalNeeded = false
    @Published var showErrorAlert = false
    @Published var barsShortcut: Shortcut = .barsStandard
    @Published var barsShortcutReady = false
    @Published var barsBusy = false
    @Published private(set) var barTargets = BarTargets()
    @Published var windowExpanded = UserDefaults.standard.object(forKey: "windowExpanded.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(windowExpanded, forKey: "windowExpanded.v1") }
    }
    @Published var barsExpanded = UserDefaults.standard.object(forKey: "barsExpanded.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(barsExpanded, forKey: "barsExpanded.v1") }
    }
    @Published private(set) var recordingKind: ShortcutKind?
    var onMinimized: (() -> Void)?
    var onStateChanged: (() -> Void)?
    private var hotKey: GlobalHotKey?
    private var barsHotKey: GlobalHotKey?
    private let barsQueue = DispatchQueue(label: "local.jingzhuo.system-bars", qos: .userInitiated)
    private var permissionTimer: Timer?
    private var recoveryTimer: Timer?
    private var recoveryBaseline: RecoveryBaseline<AXUIElement>?
    private var recoveryTargetOffset = 0
    private var recoveryGeneration = 0
    private var recoveryChecking = false
    private var recoveryCheckCancellation: CancellationFlag?
    private enum RecoveryFollowUp { case toggle, restore }
    private var recoveryFollowUp: RecoveryFollowUp?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "local.jingzhuo.windows", qos: .userInitiated)
    private var lastBatch = LastWindowBatch<BatchWindow>()
    private var cancellation: CancellationFlag?
    private var observers: [NSObjectProtocol] = []
    private static let shortcutKey = "minimizeShortcut.v1"
    private static let barsShortcutKey = "barsShortcut.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let stored = try? JSONDecoder().decode(Shortcut.self, from: data), stored.isValid { shortcut = stored }
        if let data = UserDefaults.standard.data(forKey: Self.barsShortcutKey),
           let stored = try? JSONDecoder().decode(Shortcut.self, from: data), stored.isValid { barsShortcut = stored }
        if let data = UserDefaults.standard.data(forKey: "barTargets.v1"),
           let stored = try? JSONDecoder().decode(BarTargets.self, from: data) { barTargets = stored }
        do {
            let hotKey = try GlobalHotKey()
            self.hotKey = hotKey
            hotKey.action = { [weak self] in self?.toggleWindows() }
            try hotKey.register(shortcut)
            shortcutReady = true
        } catch { setMessage(error.localizedDescription, error: true) }
        do {
            let barsKey = try GlobalHotKey(signature: 0x4A5A4252)
            barsHotKey = barsKey
            barsKey.action = { [weak self] in self?.toggleSystemBars() }
            if !barTargets.isEmpty {
                guard !barsShortcut.matches(shortcut) else { throw ShortcutError.occupied }
                try barsKey.register(barsShortcut)
                barsShortcutReady = true
            }
        } catch { setMessage(error.localizedDescription, error: true) }
        updateLoginStatus()
        // ESC remains in the source for future compatibility work, but this version
        // has no monitor instance or global keyboard tap, even for existing users.
        UserDefaults.standard.set(false, forKey: "escCloseEnabled.v1")
        UserDefaults.standard.removeObject(forKey: "showAppDock.v1")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let newValue = AXIsProcessTrusted()
            if self.trusted != newValue { self.trusted = newValue }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endRecording()
        })
        // Activation only requests a readback. It never invalidates a batch by itself.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkRecovery()
            })
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkRecovery()
        }

    }

    func setMessage(_ value: String, error: Bool = false) {
        message = value; isError = error
        if error && !isRecording { showErrorAlert = true }
        onStateChanged?()
    }

    func beginRecording(_ kind: ShortcutKind = .windows) {
        guard !busy, !barsBusy else { return }
        recordingKind = kind
        isRecording = true; hotKey?.isSuspended = true; barsHotKey?.isSuspended = true
        setMessage("按下新的组合键；Esc 取消，20 秒未输入自动结束。")
    }
    func endRecording() {
        guard isRecording else { return }
        isRecording = false; recordingKind = nil
        hotKey?.isSuspended = false; barsHotKey?.isSuspended = false
        onStateChanged?()
    }
    func saveShortcut(_ value: Shortcut) -> Bool {
        guard let hotKey else { setMessage("快捷键服务未启动，请重新打开净桌。", error: true); return false }
        guard !value.matches(barsShortcut) else { setMessage("两组快捷键不能相同，请换一组。", error: true); return false }
        do {
            try hotKey.register(value)
            shortcut = value; shortcutReady = true
            if let encoded = try? JSONEncoder().encode(value) { UserDefaults.standard.set(encoded, forKey: Self.shortcutKey) }
            setMessage("快捷键已保存：\(value.display)。")
            onStateChanged?()
            return true
        } catch { setMessage(error.localizedDescription, error: true); return false }
    }
    func invalidShortcut() { setMessage(ShortcutError.invalid.localizedDescription, error: true) }

    func saveBarsShortcut(_ value: Shortcut) -> Bool {
        guard let barsHotKey else { setMessage("系统栏快捷键服务未启动，请重新打开净桌。", error: true); return false }
        guard !value.matches(shortcut) else { setMessage("两组快捷键不能相同，请换一组。", error: true); return false }
        do {
            guard value.isValid else { throw ShortcutError.invalid }
            if !barTargets.isEmpty { try barsHotKey.register(value) }
            barsShortcut = value; barsShortcutReady = !barTargets.isEmpty
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.barsShortcutKey) }
            setMessage("系统栏快捷键已保存：\(value.display)。")
            return true
        } catch { setMessage(error.localizedDescription, error: true); return false }
    }

    func setBarTargets(_ targets: BarTargets) {
        guard !barsBusy, !isRecording else { return }
        do {
            if targets.isEmpty {
                barsHotKey?.unregister()
                barsShortcutReady = false
            } else {
                guard let barsHotKey else { throw ShortcutError.registration(-1) }
                guard !barsShortcut.matches(shortcut) else { throw ShortcutError.occupied }
                try barsHotKey.register(barsShortcut)
                barsShortcutReady = true
            }
            barTargets = targets
            if let data = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(data, forKey: "barTargets.v1") }
            onStateChanged?()
        } catch { setMessage(error.localizedDescription, error: true) }
    }

    func toggleSystemBars() {
        guard !barsBusy, !isRecording, !barTargets.isEmpty else { return }
        let targets = barTargets
        barsBusy = true
        onStateChanged?()
        barsQueue.async {
            let result = Result { try SystemBarController(access: AppleScriptBarAccess()).toggle(targets) }
            DispatchQueue.main.async {
                self.barsBusy = false
                switch result {
                case .success(let state):
                    let hide = (targets.menuBar && state.menuBar) || (targets.dock && state.dock)
                    self.setMessage(hide ? "已启用所选系统栏自动隐藏，鼠标触边时显示。" : "已关闭所选系统栏自动隐藏。")
                case .failure(let error): self.setMessage(error.localizedDescription, error: true)
                }
                self.onStateChanged?()
            }
        }
    }

    func openAutomation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }

    func selectMode(_ mode: MinimizeMode) {
        guard !busy, !isRecording else { return }
        minimizeMode = mode
        mode.save(to: .standard)
        onStateChanged?()
    }

    func openAccessibility() {
        // Checking trust does not grant access. The user enables this app in System Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    func toggleWindows() {
        guard !busy, !isRecording else { return }
        guard !lastBatch.windows.isEmpty else { minimizeAll(); return }
        checkRecovery(followUp: .toggle)
    }

    private func recoveryTargets() -> [WindowTarget] {
        let savedPIDs = Set(recoveryBaseline?.saved.map(\.pid) ?? [])
        let applications = NSWorkspace.shared.runningApplications
            .filter { ($0.activationPolicy == .regular || savedPIDs.contains($0.processIdentifier)) && !$0.isTerminated && $0.processIdentifier != getpid() }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        guard !applications.isEmpty else { return [] }
        let offset = recoveryTargetOffset % applications.count
        recoveryTargetOffset = (offset + 1) % applications.count
        let rotated = Array(applications[offset...]) + Array(applications[..<offset])
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Newly opened foreground work is checked first; rotate the rest so a
        // slow AX server cannot permanently starve later apps of observation.
        let ordered = rotated.filter { $0.processIdentifier == frontPID }
            + rotated.filter { $0.processIdentifier != frontPID && savedPIDs.contains($0.processIdentifier) }
            + rotated.filter { $0.processIdentifier != frontPID && !savedPIDs.contains($0.processIdentifier) }
        return ordered.map { WindowTarget(pid: $0.processIdentifier, name: $0.localizedName ?? "应用 \($0.processIdentifier)", isHidden: $0.isHidden) }
    }

    private func invalidateRecoveryCheck() {
        recoveryGeneration += 1
        recoveryCheckCancellation?.cancel()
        recoveryCheckCancellation = nil
        recoveryChecking = false
        recoveryFollowUp = nil
    }

    private func checkRecovery(followUp: RecoveryFollowUp? = nil) {
        guard !busy, !isRecording, !lastBatch.windows.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            if followUp != nil { setMessage("请先在系统设置中允许净桌控制窗口。", error: true) }
            return
        }
        if let followUp {
            // A shortcut needs a new snapshot, not an observation begun before
            // the user may have reopened a window.
            if recoveryChecking { invalidateRecoveryCheck() }
            recoveryFollowUp = followUp
            busy = true
            onStateChanged?()
        }
        guard !recoveryChecking else { return }
        guard let baseline = recoveryBaseline else {
            busy = false
            let action = recoveryFollowUp; recoveryFollowUp = nil
            if action != nil { performRestore() }
            return
        }
        recoveryChecking = true
        let generation = recoveryGeneration
        let targets = recoveryTargets()
        let criticalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cancel = CancellationFlag()
        recoveryCheckCancellation = cancel
        queue.async {
            let result = RecoveryInspector(access: AXWindowAccess(messagingTimeout: 0.05)).inspect(baseline, targets: targets, criticalPID: criticalPID, cancelled: { cancel.cancelled })
            DispatchQueue.main.async {
                guard generation == self.recoveryGeneration, !cancel.cancelled else { return }
                self.recoveryChecking = false
                self.recoveryCheckCancellation = nil
                self.recoveryBaseline = result.baseline
                let own = self.lastBatch.windows.compactMap { item -> NSWindow? in
                    if case .local(let window) = item, window.isMiniaturized { return window }
                    return nil
                }
                if result.reset {
                    self.lastBatch.replace(with: [])
                    self.recoveryBaseline = nil
                } else {
                    self.lastBatch.replace(with: result.saved.map { .external($0) } + own.map { .local($0) })
                    if self.lastBatch.windows.isEmpty { self.recoveryBaseline = nil }
                }
                self.updateRecoveryCount()
                let action = self.recoveryFollowUp
                self.recoveryFollowUp = nil
                if action != nil { self.busy = false }
                guard let action else { return }
                switch action {
                case .toggle:
                    if self.lastBatch.windows.isEmpty { self.minimizeAll() }
                    else if result.canRestore { self.performRestore() }
                    else { self.setMessage("暂时无法确认当前窗口状态，恢复记录已保留，请稍后重试。", error: true) }
                case .restore:
                    if !self.lastBatch.windows.isEmpty {
                        if result.canRestore { self.performRestore() }
                        else { self.setMessage("暂时无法确认当前窗口状态，恢复记录已保留，请稍后重试。", error: true) }
                    }
                }
            }
        }
    }

    func minimizeAll() {
        guard !busy else { return }
        guard !isRecording else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else { setMessage("请先在系统设置 → 隐私与安全性 → 辅助功能中允许“净桌”。", error: true); return }
        invalidateRecoveryCheck()
        recoveryBaseline = nil
        busy = true; details = []
        let mode = minimizeMode
        setMessage(mode == .sequential ? "正在顺序收起窗口…" : "正在批量收起窗口…")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targets = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid() }
            .sorted { lhs, rhs in
                if lhs.processIdentifier == frontPID { return false }
                if rhs.processIdentifier == frontPID { return true }
                return (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }
            .map { WindowTarget(pid: $0.processIdentifier, name: $0.localizedName ?? "应用 \($0.processIdentifier)", isHidden: $0.isHidden) }
        let ownCandidates = NSApp.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.miniaturizable) && !$0.styleMask.contains(.fullScreen)
        }
        let cancel = CancellationFlag(); cancellation = cancel
        queue.async {
            var ownIssued: [NSWindow] = []
            var ownRequestedAt: TimeInterval = 0
            let engine = WindowEngine(access: AXWindowAccess())
            let (report, updated) = engine.minimize(targets, mode: mode, cancelled: { cancel.cancelled }, onRequestsDispatched: {
                DispatchQueue.main.sync {
                    guard !cancel.cancelled else { return }
                    ownRequestedAt = ProcessInfo.processInfo.systemUptime
                    for window in ownCandidates where window.isVisible && !window.isMiniaturized {
                        window.miniaturize(nil); ownIssued.append(window)
                    }
                }
            })
            let baseline = RecoveryInspector(access: AXWindowAccess(messagingTimeout: 0.05)).capture(saved: updated, targets: targets)
            DispatchQueue.main.async {
                self.recoveryBaseline = baseline
                self.details = report.details
                var finalReport = report
                // In simultaneous mode our window joins the burst; sequential mode handles it last.
                let settle = ownIssued.isEmpty ? 0 : max(0, 0.7 - (ProcessInfo.processInfo.systemUptime - ownRequestedAt))
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    var batch = baseline.saved.map { BatchWindow.external($0) }
                    for window in ownIssued {
                        if window.isMiniaturized {
                            finalReport.succeeded += 1
                        } else {
                            finalReport.failed += 1; self.details.append("净桌：设置窗口未能最小化。")
                        }
                        batch.append(.local(window))
                    }
                    self.lastBatch.replace(with: batch)
                    self.busy = false; self.cancellation = nil
                    self.updateRecoveryCount()
                    let hint = batch.isEmpty ? "" : " 再按同一快捷键，仅恢复上次收起的窗口。"
                    self.setMessage(finalReport.summary + hint, error: finalReport.failed > 0 || finalReport.interrupted)
                    self.onMinimized?()
                }
            }
        }
    }

    func restoreWindows() {
        guard !busy, !isRecording, !lastBatch.windows.isEmpty else { return }
        checkRecovery(followUp: .restore)
    }

    private func performRestore() {
        guard !busy, !isRecording, !lastBatch.windows.isEmpty else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else { setMessage("恢复其他应用窗口也需要“辅助功能”权限，请先授权。", error: true); return }
        invalidateRecoveryCheck()
        let targets = recoveryTargets()
        busy = true; details = []
        setMessage("正在恢复上次收起的那批窗口…")
        let saved = lastBatch.windows.compactMap { window -> EngineSaved<AXUIElement>? in
            if case .external(let value) = window { return value }; return nil
        }
        let ownSaved = lastBatch.windows.compactMap { window -> NSWindow? in
            if case .local(let value) = window { return value }; return nil
        }
        let cancel = CancellationFlag(); cancellation = cancel
        queue.async {
            var ownToRestore: [NSWindow] = []
            var ownRequestedAt: TimeInterval = 0
            let (count, pending, details) = WindowEngine(access: AXWindowAccess()).restore(saved, cancelled: { cancel.cancelled }, onRequestsDispatched: {
                DispatchQueue.main.sync {
                    guard !cancel.cancelled else { return }
                    ownToRestore = ownSaved.filter { $0.isMiniaturized }
                    ownRequestedAt = ProcessInfo.processInfo.systemUptime
                    for window in ownToRestore { window.deminiaturize(nil) }
                }
            })
            let baseline = RecoveryInspector(access: AXWindowAccess(messagingTimeout: 0.05)).capture(saved: pending, targets: targets)
            DispatchQueue.main.async {
                self.recoveryBaseline = baseline
                let settle = ownToRestore.isEmpty ? 0 : max(0, 0.7 - (ProcessInfo.processInfo.systemUptime - ownRequestedAt))
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    let restored = count + ownToRestore.filter { !$0.isMiniaturized }.count
                    let ownPending = ownSaved.filter { $0.isMiniaturized }
                    self.lastBatch.finishRestore(pending: baseline.saved.map { .external($0) } + ownPending.map { .local($0) })
                    self.details = details
                    self.busy = false; self.cancellation = nil; self.updateRecoveryCount()
                    let remaining = self.lastBatch.windows.count
                    let suffix = remaining == 0 ? "。下次按快捷键将开始新一轮收起。" : "，仍有 \(remaining) 个窗口待恢复，再按快捷键重试。"
                    self.setMessage("已恢复上次的 \(restored) 个窗口" + suffix, error: remaining > 0)
                }
            }
        }
    }

    func cancelOperation() {
        cancellation?.cancel()
        if recoveryFollowUp != nil {
            invalidateRecoveryCheck(); busy = false
        }
        setMessage("正在停止，已完成的窗口仍可恢复…")
    }

    private func updateRecoveryCount() {
        recoverableCount = lastBatch.windows.count
        nextAction = lastBatch.nextAction
        onStateChanged?()
    }

    func updateLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginApprovalNeeded = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
            if loginApprovalNeeded { setMessage("请在系统设置 → 通用 → 登录项中批准净桌。") }
        } catch { updateLoginStatus(); setMessage("登录时启动设置失败：\(error.localizedDescription)", error: true) }
    }

    func stop() {
        invalidateRecoveryCheck()
        recoveryTimer?.invalidate()
        cancellation?.cancel(); hotKey?.stop(); barsHotKey?.stop(); permissionTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
