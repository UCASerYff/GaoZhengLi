import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            Form {
                Toggle("监听已授权目录的变更提示", isOn: $model.config.automaticMonitoring).onChange(of: model.config.automaticMonitoring) { _, _ in model.saveConfig(); model.configureMonitor() }
                Text("FSEvents 仅提示可能发生变化，随后由安全扫描核对。退出程序时停止监听；移动卷、网络卷可单独暂停。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("文件内容", value: "索引不读取正文，不主动下载占位文件")
                LabeledContent("物理整理", value: "每次预览与单独确认，默认不覆盖")
                LabeledContent("跨应用", value: "只经用户确认传递引用或有界副本")
                Text("添加目录使用主窗口工具栏或 ⌘O。默认打开方式在主窗口“默认打开方式”管理。").foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("功能", systemImage: "switch.2") }
            Form {
                Picker("外观", selection: $model.config.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.onChange(of: model.config.appearance) { _, _ in model.saveConfig() }
                Text("使用系统原生表格、侧栏和快捷键。工作区面板可折叠、暂停、排序。").foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            VStack(alignment: .leading, spacing: 16) {
                Text("本地资料与恢复").font(.headline)
                Text(AppLocations.directory.path).font(.caption).textSelection(.enabled)
                Text("备份包含索引、授权书签、配置、关联历史、整理与交接账本，含敏感元数据，请妥善保管。核验备份不会上传到 GitHub。").foregroundStyle(.secondary)
                HStack {
                    Button("创建核验备份") { Task { await model.createBackup() } }.disabled(model.backingUp || model.moving)
                    Button("显示资料") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLocations.directory.path) }
                    Button("显示备份") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLocations.backups.path) }
                }
                Text("恢复时先退出程序，保留当前资料，将完整核验备份恢复到原目录；保留同一钥匙串与签名。缺库、摘要不符或过新格式会停止写入。不要删除初始化标记来重置。").font(.caption).foregroundStyle(.secondary)
                Text(model.status).font(.caption).textSelection(.enabled)
                if model.backingUp { ProgressView("正在创建并核对备份…") }
                Spacer()
            }.padding(24).tabItem { Label("数据", systemImage: "externaldrive") }
            VStack(spacing: 14) {
                Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "png") ?? URL(fileURLWithPath: "/")) ?? NSImage()).resizable().frame(width: 100, height: 100)
                Text("搞整理 V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00")").font(.title2.bold())
                Text("快速找文件 · 虚拟工作区 · 打开方式管理")
                Text("原件留在原位置，整理从清晰的引用开始。").foregroundStyle(.secondary)
                Text("Apple Silicon · macOS 14+ · 无遥测 · 无云端索引").font(.caption).foregroundStyle(.secondary)
                Link("源码与发行", destination: URL(string: "https://github.com/UCASerYff/GaoZhengLi")!)
                Text("MIT License · Apple Development 本机签名，未公证").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("关于", systemImage: "info.circle") }
        }.disabled(model.backingUp)
    }
}
