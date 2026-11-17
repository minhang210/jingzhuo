import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "M")
    static let barsStandard = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), label: "H")
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    static let knownModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.knownModifiers == 0 &&
        modifiers & UInt32(controlKey | cmdKey) != 0 &&
        ![UInt32(kVK_Escape), UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_Option), UInt32(kVK_Control), UInt32(kVK_CapsLock), UInt32(kVK_RightCommand), UInt32(kVK_RightShift), UInt32(kVK_RightOption), UInt32(kVK_RightControl), UInt32(kVK_Function)].contains(keyCode) &&
        !label.isEmpty && label.count <= 24
    }

    var display: String {
        [(modifiers & UInt32(controlKey) != 0 ? "⌃" : ""),
         (modifiers & UInt32(optionKey) != 0 ? "⌥" : ""),
         (modifiers & UInt32(shiftKey) != 0 ? "⇧" : ""),
         (modifiers & UInt32(cmdKey) != 0 ? "⌘" : ""), label].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func from(_ event: NSEvent) -> Shortcut? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        let special: [UInt16: String] = [49:"Space",36:"Return",76:"Enter",48:"Tab",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        let text = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: m, label: text)
        return shortcut.isValid ? shortcut : nil
    }
}

enum ShortcutError: LocalizedError {
    case invalid, occupied, systemReserved, registration(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid: return "请包含 Control（⌃）或 Command（⌘），再搭配一个按键。"
        case .occupied: return "这个快捷键已被占用，请换一组。原快捷键已保留。"
        case .systemReserved: return "这个组合已用于系统快捷键，请换一组。"
        case .registration(let code): return "快捷键注册失败（\(code)），请换一组后重试。"
        }
    }
}

final class GlobalHotKey {
    private var handler: EventHandlerRef?
    private var ref: EventHotKeyRef?
    private var current: Shortcut?
    private var nextID: UInt32 = 1
    private var activeID: UInt32 = 0
    private var keyHeld = false
    var isSuspended = false
    var action: (() -> Void)?
    private let signature: OSType

    init(signature: OSType = 0x4A5A4854) throws {
        self.signature = signature
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == owner.signature, id.id == owner.activeID else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.keyHeld = false; return noErr }
            guard !owner.keyHeld else { return noErr }
            owner.keyHeld = true
            if !owner.isSuspended { owner.action?() }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw ShortcutError.registration(status) }
    }

    func register(_ shortcut: Shortcut) throws {
        precondition(Thread.isMainThread)
        guard shortcut.isValid else { throw ShortcutError.invalid }
        if current == shortcut, ref != nil { return }
        var symbolicKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolicKeys) == noErr, let entries = symbolicKeys?.takeRetainedValue() as? [[String: Any]] {
            for entry in entries where (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true {
                if (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode &&
                    ((entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0) & Shortcut.knownModifiers == shortcut.modifiers {
                    throw ShortcutError.systemReserved
                }
            }
        }
        let id = nextID
        nextID &+= 1
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr, let candidate else {
            if status == eventHotKeyExistsErr { throw ShortcutError.occupied }
            throw ShortcutError.registration(status)
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = candidate; current = shortcut; activeID = id; keyHeld = false
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        current = nil; keyHeld = false
    }
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        keyHeld = false
    }
    deinit { stop() }
}

// This recorder receives only events directed to its own settings control.
// It does not install a global keyboard monitor.
final class ShortcutButton: NSButton {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onRecord: ((Shortcut) -> Bool)?
    var onInvalid: (() -> Void)?
    var text = ""
    private(set) var recording = false
    private var timeout: Timer?
    override var acceptsFirstResponder: Bool { true }

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel("设置收起/展开窗口快捷键")
    }
    @objc func beginRecording() {
        guard !recording else { return }
        recording = true; title = "请按组合键…"
        window?.makeFirstResponder(self); onBegin?()
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in self?.finish() }
    }
    func finish() {
        guard recording else { return }
        recording = false; timeout?.invalidate(); timeout = nil
        title = text; onEnd?()
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { finish() }; super.viewWillMove(toWindow: newWindow) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }
    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { finish(); return }
        guard let value = Shortcut.from(event) else { onInvalid?(); return }
        if onRecord?(value) == true { finish() }
    }
    func cancelRecording() { finish() }
}
