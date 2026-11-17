import AppKit

struct BarTargets: Codable, Equatable {
    var menuBar = true
    var dock = true
    var isEmpty: Bool { !menuBar && !dock }
}

struct BarState: Equatable {
    var menuBar: Bool
    var dock: Bool
}

enum SystemBarError: LocalizedError {
    case noTargets, automationDenied, execution(String), malformedResponse, verificationFailed
    var errorDescription: String? {
        switch self {
        case .noTargets: return "请先选择菜单栏或程序坞。"
        case .automationDenied: return "请在系统设置 → 隐私与安全性 → 自动化中，允许净桌控制 System Events（系统事件），然后重试。"
        case .execution(let text): return "系统显示设置未能修改：\(text)"
        case .malformedResponse: return "系统没有返回有效的显示设置，请重试。"
        case .verificationFailed: return "系统没有确认显示设置已修改，已尝试恢复修改前的设置。"
        }
    }
}

protocol SystemBarAccess {
    func read() throws -> BarState
    func write(_ state: BarState, targets: BarTargets) throws
}

struct SystemBarController<Access: SystemBarAccess> {
    let access: Access
    func toggle(_ targets: BarTargets) throws -> BarState {
        guard !targets.isEmpty else { throw SystemBarError.noTargets }
        let before = try access.read()
        // If any selected bar is not auto-hiding, enable auto-hide for all selected bars.
        // If all selected bars already auto-hide, show them permanently.
        let hide = !((!targets.menuBar || before.menuBar) && (!targets.dock || before.dock))
        let desired = BarState(menuBar: targets.menuBar ? hide : before.menuBar,
                               dock: targets.dock ? hide : before.dock)
        do {
            try access.write(desired, targets: targets)
            let actual = try access.read()
            guard (!targets.menuBar || actual.menuBar == desired.menuBar) &&
                  (!targets.dock || actual.dock == desired.dock) else {
                throw SystemBarError.verificationFailed
            }
            return actual
        } catch {
            // Do not touch unselected preferences, including during rollback.
            try? access.write(before, targets: targets)
            throw error
        }
    }
}

// Uses the System Events scripting dictionary's dock preferences object.
// Only the autohide and autohide menu bar properties are ever written.
struct AppleScriptBarAccess: SystemBarAccess {
    private func execute(_ body: String) throws -> NSAppleEventDescriptor {
        let source = """
        with timeout of 15 seconds
            tell application id "com.apple.systemevents"
                tell dock preferences
                    \(body)
                end tell
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { throw SystemBarError.malformedResponse }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if code == -1743 { throw SystemBarError.automationDenied }
            throw SystemBarError.execution(error[NSAppleScript.errorMessage] as? String ?? "未知错误")
        }
        return result
    }
    func read() throws -> BarState {
        let reply = try execute("return {autohide menu bar, autohide}")
        guard reply.numberOfItems == 2,
              let menu = reply.atIndex(1), let dock = reply.atIndex(2),
              [OSType(0x626F6F6C), OSType(0x74727565), OSType(0x66616C73)].contains(menu.descriptorType),
              [OSType(0x626F6F6C), OSType(0x74727565), OSType(0x66616C73)].contains(dock.descriptorType) else {
            throw SystemBarError.malformedResponse
        }
        return BarState(menuBar: menu.booleanValue, dock: dock.booleanValue)
    }
    func write(_ state: BarState, targets: BarTargets) throws {
        guard !targets.isEmpty else { return }
        var lines: [String] = []
        if targets.menuBar { lines.append("set autohide menu bar to \(state.menuBar ? "true" : "false")") }
        if targets.dock { lines.append("set autohide to \(state.dock ? "true" : "false")") }
        _ = try execute(lines.joined(separator: "\n"))
    }
}

enum ShortcutKind: Equatable {
    case windows, bars
}
