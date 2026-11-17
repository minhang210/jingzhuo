import AppKit
import SwiftUI
import ServiceManagement

private let green = Color(red: 0.14, green: 0.39, blue: 0.32)

// Native button with its focus ring explicitly disabled on both view and cell.
// It remains in the keyboard navigation chain.
private final class DisclosureButton: NSButton {
    var onToggle: (() -> Void)?
    override func drawFocusRingMask() {}
    override var focusRingMaskBounds: NSRect { .zero }
    @objc func toggleDisclosure() { onToggle?() }
}

private struct DisclosureControl: NSViewRepresentable {
    let title: String
    @Binding var expanded: Bool
    func makeNSView(context: Context) -> DisclosureButton {
        let view = DisclosureButton(frame: .zero)
        view.isBordered = false
        view.bezelStyle = .regularSquare
        view.imagePosition = .imageOnly
        view.focusRingType = .none
        view.cell?.focusRingType = .none
        view.target = view; view.action = #selector(DisclosureButton.toggleDisclosure)
        return view
    }
    func updateNSView(_ view: DisclosureButton, context: Context) {
        view.onToggle = { expanded.toggle() }
        view.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        view.contentTintColor = .secondaryLabelColor
        view.focusRingType = .none; view.cell?.focusRingType = .none
        view.setAccessibilityLabel((expanded ? "折叠" : "展开") + title + "选项")
        view.setAccessibilityValue(expanded ? "展开" : "折叠")
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var kind: ShortcutKind = .windows
    func makeNSView(context: Context) -> ShortcutButton {
        let view = ShortcutButton()
        view.onBegin = { model.beginRecording(kind) }
        view.onEnd = { model.endRecording() }
        view.onRecord = { kind == .windows ? model.saveShortcut($0) : model.saveBarsShortcut($0) }
        view.onInvalid = { model.invalidShortcut() }
        return view
    }
    func updateNSView(_ view: ShortcutButton, context: Context) {
        view.text = (kind == .windows ? model.shortcut : model.barsShortcut).display
        if (!model.isRecording || model.recordingKind != kind) && view.recording { view.cancelRecording() }
        if !view.recording { view.title = view.text }
        view.isEnabled = !model.busy && !model.barsBusy && (kind == .windows || !model.barTargets.isEmpty)
        view.setAccessibilityLabel(kind == .windows ? "设置收起/展开窗口快捷键" : "设置隐藏/展开菜单栏和程序坞快捷键")
        view.setAccessibilityHelp("点击后按下新的组合键。Esc 取消。")
    }
    static func dismantleNSView(_ view: ShortcutButton, coordinator: ()) { view.cancelRecording() }
}

private struct AppLogo: View {
    private static let logo: NSImage? = {
        guard let path = Bundle.main.url(forResource: "AppIcon-Preview", withExtension: "png") else { return nil }
        return NSImage(contentsOf: path)
    }()
    var body: some View {
        if let logo = Self.logo {
            Image(nsImage: logo).resizable().interpolation(.high)
                .frame(width: 58, height: 58).accessibilityHidden(true)
        } else {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 25, weight: .regular)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(green.gradient, in: RoundedRectangle(cornerRadius: 17))
                .padding(5).accessibilityHidden(true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.6"
    }

    private func modeButton(_ mode: MinimizeMode) -> some View {
        let selected = model.minimizeMode == mode
        return Button { model.selectMode(mode) } label: {
            HStack(spacing: 4) {
                Image(systemName: mode == .sequential ? "list.number" : "square.3.layers.3d")
                    .font(.system(size: 10))
                Text(mode.title).font(.system(size: 11))
            }
            .fixedSize().padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? green.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? green.opacity(0.6) : Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .disabled(model.busy || model.isRecording)
    }

    private func fold(_ title: String, expanded: Binding<Bool>) -> some View {
        DisclosureControl(title: title, expanded: expanded).frame(width: 24, height: 28)
    }

    private func targetButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11))
            }
            .fixedSize().padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? green.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? green.opacity(0.6) : Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "未选择")
        .disabled(model.barsBusy || model.isRecording)
    }

    private func heading(_ title: String, kind: ShortcutKind, expanded: Binding<Bool>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                fold(title, expanded: expanded)
                Text(title).font(.system(size: 13, weight: .medium)).fixedSize()
                Spacer(minLength: 0)
                ShortcutRecorder(model: model, kind: kind).frame(width: 104, height: 32)
            }
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    fold(title, expanded: expanded)
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer()
                    ShortcutRecorder(model: model, kind: kind).frame(width: 104, height: 32)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppLogo()
                VStack(alignment: .leading, spacing: 5) {
                    Text("净桌").font(.system(size: 24, weight: .semibold))
                    Text("收起纷扰，随时回来。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 9) {
                HStack {
                    Text("登录时启动").font(.system(size: 13)); Spacer()
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled || model.loginApprovalNeeded }, set: model.setLogin))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                }.frame(minHeight: 31)
                HStack {
                    Text("在程序坞显示").font(.system(size: 13)); Spacer()
                    Toggle("在程序坞显示", isOn: Binding(get: { model.showAppDock }, set: model.setShowAppDock))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.busy || model.barsBusy)
                }.frame(minHeight: 31)
                HStack {
                    Text("是否ESC关闭当前窗口").font(.system(size: 13)); Spacer()
                    Toggle("是否ESC关闭当前窗口", isOn: Binding(get: { model.escCloseEnabled }, set: model.setEscapeClose))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.busy || model.barsBusy || model.isRecording)
                }.frame(minHeight: 31)
            }.padding(.top, 23)

            Divider().padding(.top, 16).padding(.bottom, 15)
            heading("收起/展开窗口", kind: .windows, expanded: $model.windowExpanded)
            if model.isRecording && model.recordingKind == .windows { recordingHint }
            if model.windowExpanded {
                HStack(spacing: 6) {
                    modeButton(.sequential); modeButton(.simultaneous); Spacer(minLength: 0)
                }.padding(.leading, 31).padding(.top, 9)
            }
            Divider().padding(.top, 16).padding(.bottom, 15)
            heading("隐藏/展开菜单栏和程序坞", kind: .bars, expanded: $model.barsExpanded)
            if model.isRecording && model.recordingKind == .bars { recordingHint }
            if model.barsExpanded {
                HStack(spacing: 6) {
                    targetButton("菜单栏", symbol: "menubar.rectangle", selected: model.barTargets.menuBar) {
                        var targets = model.barTargets; targets.menuBar.toggle(); model.setBarTargets(targets)
                    }
                    targetButton("程序坞", symbol: "dock.rectangle", selected: model.barTargets.dock) {
                        var targets = model.barTargets; targets.dock.toggle(); model.setBarTargets(targets)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 31).padding(.top, 9)
            }
            Spacer(minLength: 22)
            
            if model.loginApprovalNeeded {
                Button("批准登录项") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link).font(.system(size: 11)).padding(.bottom, 8)
            }
            HStack {
                if model.trusted {
                    Label("已授权", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button("授权控制窗口", action: model.openAccessibility)
                        .buttonStyle(.link).font(.system(size: 11)).disabled(model.busy)
                }
                Spacer(minLength: 4)
                Text("版本号：\(version)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 19)
        .frame(minWidth: 294, idealWidth: 400).frame(minHeight: 352)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("操作未完成", isPresented: $model.showErrorAlert) {
            if !model.trusted { Button("窗口控制授权", action: model.openAccessibility) }
            Button("自动化设置", action: model.openAutomation)
            Button("知道了", role: .cancel) {}
        } message: { Text(model.message) }
        .onAppear { model.updateLoginStatus() }
        .onChange(of: model.showErrorAlert) { _ in model.updateEscapeSuspension() }
    }

    private var recordingHint: some View {
        Text(model.isError ? model.message : "按下新的组合键 · Esc 取消")
            .font(.system(size: 11)).foregroundStyle(model.isError ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 5)
            .fixedSize(horizontal: false, vertical: true)
    }
}
