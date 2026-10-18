import SwiftUI
import AppKit

struct AssociationsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: AssociationController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("默认打开方式").font(.title2.bold())
                Text("按文件类型或 URL scheme 管理默认应用。单次打开可在文件右键菜单中选择。").foregroundStyle(.secondary)
                HStack {
                    Picker("作用范围", selection: $controller.mode) { Text("全部同类型文件").tag("type"); Text("URL scheme").tag("scheme") }.frame(width: 235)
                    TextField(controller.mode == "type" ? "public.jpeg" : "例如 mailto", text: $controller.identifier).textFieldStyle(.roundedBorder)
                    Button("读取系统关联") { controller.refresh() }
                }.disabled(controller.busy)
                GroupBox("当前系统默认应用") {
                    HStack { Image(systemName: "app").font(.title2); VStack(alignment: .leading) { Text(controller.current?.deletingPathExtension().lastPathComponent ?? "尚未读取 / 未设置").font(.headline); if let current = controller.current { Text(current.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }; Spacer() }.padding(8)
                }
                GroupBox("已安装候选") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("应用", selection: $controller.selected) {
                            Text("请选择").tag(nil as URL?)
                            ForEach(controller.candidates, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag(Optional($0)) }
                        }
                        HStack {
                            Button("选择其他已安装应用…") {
                                let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = [.applicationBundle]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                                if p.runModal() == .OK, let app = p.url { if !controller.candidates.contains(app) { controller.candidates.append(app) }; controller.selected = app }
                            }
                            Spacer()
                            Button("确认变更…") {
                                guard let app = controller.selected else { return }
                                guard confirm(title: "修改默认打开应用？", message: "范围：\(controller.mode == "type" ? "所有此类型文件" : "此 URL scheme")\n标识：\(controller.identifier)\n旧应用：\(controller.current?.lastPathComponent ?? "无")\n新应用：\(app.lastPathComponent)\n系统可能另行要求确认，最终以读回结果为准。", action: "提交系统确认") else { return }
                                Task {
                                    let success = await controller.change(to: app)
                                    if let context = model.exchange?.context, context.action == "associations.manage", controller.mode == "type", context.uti.isEmpty || context.uti == controller.identifier {
                                        await model.exchange?.finishProvider(status: success ? .completed : .failed, provenance: ["workflowState": success ? "changed" : "failed", "readBackVerified": success, "uti": controller.identifier])
                                    }
                                }
                            }.buttonStyle(.borderedProminent).disabled(controller.selected == nil || controller.busy)
                        }
                    }.padding(8)
                }
                Text(controller.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if controller.busy { ProgressView("等待系统确认并核对实际关联…") }
                Text("变更记录与恢复").font(.headline)
                ForEach(controller.history.prefix(50)) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.identifier) → \(record.requestedApplication.lastPathComponent)")
                            Text("\(record.status) · \(record.detail)").font(.caption).foregroundStyle(.secondary)
                            Text(record.date, format: .dateTime).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if record.previousApplication != nil { Button("恢复旧关联…") { guard confirm(title: "恢复旧关联？", message: "将 \(record.identifier) 恢复为 \(record.previousApplication!.lastPathComponent)，之后读取系统实际结果。", action: "恢复") else { return }; Task { _ = await controller.restore(record) } }.disabled(controller.busy) }
                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
}
struct MoveView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("物理整理计划").font(.title2.bold())
                Text("从搜索结果选择文件并生成预览。V1 支持同卷普通文件；跨卷、目录包、符号链接、硬链接及云端占位文件均会拒绝。重名不覆盖，可在执行前重命名。整体批次并非原子事务。").foregroundStyle(.secondary)
                if model.moving { ProgressView("正在核验或执行，可请求取消；已完成项目保持可恢复日志。") }
                if let plan = model.movePlan {
                    GroupBox("当前计划 · \(plan.state.rawValue)") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(plan.id.uuidString).font(.caption).textSelection(.enabled)
                            Text("\(plan.operations.count) 项 · \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))")
                            ForEach(plan.operations) { operation in OperationRow(operation: operation) }
                            if let failure = plan.failure { Text(failure).foregroundStyle(.orange) }
                            HStack {
                                Button("执行此预览计划…") { Task { await model.executeMove() } }.buttonStyle(.borderedProminent).disabled(plan.state != .awaitingConfirmation || model.moving)
                                Button(model.moving ? "请求取消" : "取消计划") { model.cancelMove() }
                            }
                        }.padding(10)
                    }
                }
                HStack { Text("持久记录与恢复").font(.headline); Spacer(); Button("刷新") { model.refreshMoveHistory() }.disabled(model.moving) }
                if model.moveHistory.isEmpty { Text("尚无计划。仅建立虚拟面板不会出现在此处。").foregroundStyle(.secondary) }
                ForEach(model.moveHistory.sorted(by: { $0.createdAt > $1.createdAt })) { plan in
                    DisclosureGroup("\(plan.createdAt.formatted()) · \(plan.state.rawValue) · \(plan.operations.count) 项") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.operations) { operation in
                                OperationRow(operation: operation)
                                ForEach(operation.journal) { entry in Text("\(entry.phase) · \(entry.detail)").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let failure = plan.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                            Button("重新授权并恢复原位置…") { Task { await model.rollbackMove(plan) } }.disabled(model.moving)
                        }.padding(12)
                    }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
}
struct OperationRow: View {
    let operation: MoveOperation
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(operation.source.path).textSelection(.enabled)
            Label(operation.destination.path, systemImage: "arrow.turn.down.right").textSelection(.enabled)
            Text(operation.state.rawValue).font(.caption).foregroundStyle(.secondary)
            if let failure = operation.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.font(.callout)
    }
}
struct ExchangeBanner: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var service: GaoExchangeService
    var body: some View {
        if let context = service.context {
            HStack {
                VStack(alignment: .leading) { Text("处理 \(context.action)").font(.headline); Text("来源声明：\(context.manifest.sourceBundleID) · 原件引用需接收方独立授权").font(.caption) }
                if !model.incomingScopeNote.isEmpty { Text(model.incomingScopeNote).font(.caption).lineLimit(3) }
                Spacer()
                if ["files.search", "files.choose"].contains(context.action) {
                    if context.scope != nil { Button("授权请求范围…") { model.authorizeRequestScope() } }
                    Button("系统选择…") { Task { await model.chooseForRequest() } }
                    Button("发送所选") { Task { await model.returnSelected() } }.disabled(model.selection.isEmpty)
                }
                Button("取消请求") { Task { await service.cancelContext() } }
            }.padding(12).background(.tint.opacity(0.08))
        } else if service.preparedResult != nil {
            HStack { Text("回执已生成，等待你明确发送。").font(.callout); Spacer(); Button("发送结果") { Task { await service.sendPreparedResult() } }.buttonStyle(.borderedProminent); Button("查看记录") { model.section = .exchange } }.padding(12).background(.tint.opacity(0.08))
        } else if service.review != nil {
            HStack { Label("收到跨应用请求，等待核对。", systemImage: "envelope"); Spacer(); Button("核对请求") { model.section = .exchange } }.padding(12).background(.tint.opacity(0.08))
        }
    }
}
struct ExchangeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var service: GaoExchangeService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("跨应用交接").font(.title2.bold()); Spacer(); Button("接收动作包…") { model.chooseActionPackage() } }
                Text("GaoAction V1 · 请求先核对，选择与关联变更均需你确认。来源声明不是发送者身份认证，接收方仍需独立核对权限。").foregroundStyle(.secondary)
                if let review = service.review {
                    GroupBox("核对收到的交接") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(review.summary).textSelection(.enabled)
                            ForEach(review.manifest.items, id: \.id) { item in Text("附件：\(item.relativePath) · \(item.byteCount) 字节").font(.caption).textSelection(.enabled) }
                            ForEach(review.manifest.references, id: \.id) { ref in Text("引用：\(ref.displayName) · \(ref.fileURL ?? "无路径")").font(.caption).textSelection(.enabled) }
                            HStack { Button("接受并处理") { Task { await service.acceptReview(); model.routeContext() } }.buttonStyle(.borderedProminent); Button("取消 / 保留待核对") { Task { await service.rejectReview() } } }
                        }.padding(10)
                    }
                }
                if service.context?.action == "files.reveal" { Button("系统面板核对并定位原件…") { Task { await model.revealRequest() } }.buttonStyle(.borderedProminent) }
                if let error = service.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                Text(service.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if service.busy { ProgressView() }
                Text("本机提供方").font(.headline)
                ForEach(GaoExchangeDocumentTarget.allCases, id: \.bundleID) { target in
                    let unavailable = service.providerAvailability(target)
                    HStack { Text(target == .files ? "搞文件 · documents.open" : "搞研究 · research.importDocuments"); Spacer(); Text(unavailable ?? "能力表与版本匹配").font(.caption).foregroundStyle(unavailable == nil ? Color.secondary : .orange) }
                }
                Text("交接记录").font(.headline)
                ForEach(service.records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(record.manifest.action) · \(record.direction == "in" ? "接收" : "发送")").font(.headline)
                        Text("\(record.phase.rawValue) / \(record.businessStatus?.rawValue ?? "pending")").font(.caption).foregroundStyle(.secondary)
                        Text(record.manifest.requestID).font(.caption2).textSelection(.enabled)
                        HStack {
                            if record.direction == "in" && record.phase == .received { Button("继续核对") { Task { await service.resumeReview(record) } } }
                            if record.direction == "out" && record.manifest.kind == .result && (record.phase == .prepared || record.phase == .interrupted) { Button("准备发送结果") { service.prepareToSend(record) } }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
}
