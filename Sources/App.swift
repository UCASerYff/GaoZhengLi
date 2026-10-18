import SwiftUI
import AppKit

@main struct GaoZhengLiApp: App {
    @NSApplicationDelegateAdaptor(GaoAppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("搞整理 V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00")", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(model.config.appearance == "light" ? .light : model.config.appearance == "dark" ? .dark : nil)
                .onOpenURL { url in Task { await model.receive(url) } }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加授权目录…") { model.addRoot() }.keyboardShortcut("o")
                Button("新建工作区…") { model.createWorkspace() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("接收动作包…") { model.chooseActionPackage() }
            }
            CommandMenu("文件") {
                Button("打开所选") { model.openSelected() }.keyboardShortcut(.return, modifiers: .command)
                Button("在 Finder 显示") { model.revealSelected() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("复制所选路径") { model.copySelectedPaths() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("保存当前查询…") { model.saveQuery() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView().environmentObject(model).frame(width: 630, height: 460) }
    }
}
final class GaoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { NotificationCenter.default.post(name: .gaoTerminate, object: nil) }
}
extension Notification.Name { static let gaoTerminate = Notification.Name("GaoZhengLi.terminate") }

@MainActor func askText(title: String, message: String, initial: String = "") -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
    let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 330, height: 25)
    alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
@MainActor func confirm(title: String, message: String, action: String = "确认") -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
    alert.addButton(withTitle: action); alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
}
