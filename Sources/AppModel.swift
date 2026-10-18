import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum AppSection: Hashable { case search, favorites, roots, associations, moves, exchange, workspace(UUID) }

@MainActor final class AppModel: ObservableObject {
    @Published var config = LibraryConfiguration()
    @Published var section: AppSection = .search
    @Published var roots: [IndexRoot] = []
    @Published var filter = SearchFilter()
    @Published var result = SearchPage(files: [], totalCount: 0, page: 0, pageSize: 100)
    @Published var selection = Set<String>()
    @Published var page = 0
    @Published var searching = false
    @Published var scanMessage = "尚未添加授权目录"
    @Published var scanning = false
    @Published var status = ""
    @Published var fatalError: String?
    @Published var movePlan: MovePlan?
    @Published var moveHistory: [MovePlan] = []
    @Published var moving = false
    @Published var backingUp = false
    @Published var incomingScopeNote = ""
    @Published var dataRevision = UUID()
    var index: IndexStore?
    var associations: AssociationController?
    var exchange: GaoExchangeService?
    var mover: MoveEngine?
    var directory: URL?
    private var configDocument: ProtectedDocument<LibraryConfiguration>?
    private var scanFlag: CancellationFlag?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var monitor: IndexMonitor?
    private var backgroundObserver: NSObjectProtocol?
    private var pendingScanRoots = Set<UUID>()
    private var moveAuthorization: MoveAuthorization?
    private var moveLeases: [IndexAccessLease] = []
    private var destinationScope: URL?

    init() {
        do {
            let dir = try AppLocations.prepare(); directory = dir
            let doc = ProtectedDocument<LibraryConfiguration>(directory: dir, name: "configuration")
            config = try doc.load(initial: LibraryConfiguration()); guard config.schemaVersion == 1 else { throw AppFailure("工作区资料格式过新，停止写入。") }; configDocument = doc
            index = try IndexStore(directory: dir)
            associations = try AssociationController(directory: dir)
            exchange = GaoExchangeService(dataDirectory: dir); exchange?.loadHistory()
            if let error = exchange?.error { throw AppFailure(error) }
            mover = try MoveEngine(directory: dir.appendingPathComponent("MovePlans", isDirectory: true))
            moveHistory = mover?.allPlans() ?? []
            AppLocations.markInitialized()
            refreshRoots(); configureMonitor()
            for root in roots where !root.isPaused { queueScan(root.id) }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; for root in self.roots where !root.isPaused { self.queueScan(root.id) } }
            }
            backgroundObserver = NotificationCenter.default.addObserver(forName: .gaoTerminate, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.shutdown() }
            }
            refreshSearch()
        } catch { fatalError = error.localizedDescription }
    }
    func stopForBackup() { pendingScanRoots.removeAll(); scanFlag?.cancel(); monitor?.stop() }
    func shutdown() { scanFlag?.cancel(); monitor?.stop(); searchTask?.cancel(); if let id = movePlan?.id { mover?.requestCancel(id: id) }; if !moving { releaseMoveScopes() } }
    func saveConfig() {
        guard fatalError == nil, !backingUp else { return }
        do { try configDocument?.save(config); dataRevision = UUID() } catch { fatalError = error.localizedDescription }
    }
    func refreshRoots() { do { roots = try index?.roots() ?? [] } catch { status = error.localizedDescription } }
    func configureMonitor() {
        monitor?.stop()
        guard config.automaticMonitoring, let index else { return }
        // Every event is advisory. The monitor requests a bounded, debounced reconciliation.
        monitor = IndexMonitor(store: index) { [weak self] rootID in
            Task { @MainActor in self?.queueScan(rootID) }
        }
        do { try monitor?.start() } catch { status = error.localizedDescription }
    }
    func addRoot(suggested: URL? = nil) {
        guard fatalError == nil, !backingUp, let index else { return }
        let panel = NSOpenPanel(); panel.title = "选择要索引的目录"; panel.message = "只读取所选范围的元数据；不读取正文、不搬动原文件。"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.directoryURL = suggested
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { let root = try index.addRoot(url: url); queueScan(root.id) } catch { status = error.localizedDescription }
        }
        refreshRoots(); configureMonitor()
    }
    func queueScan(_ id: UUID) {
        pendingScanRoots.insert(id)
        startNextScan()
    }
    private func startNextScan() {
        guard !scanning, !backingUp, !moving, let id = pendingScanRoots.first, let index, fatalError == nil else { return }
        pendingScanRoots.remove(id); scanning = true
        let flag = CancellationFlag(); scanFlag = flag
        scanMessage = "正在扫描授权目录…"
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try index.scan(rootID: id, cancel: { flag.isCancelled }, progress: { progress in
                        Task { @MainActor [weak self = self] in self?.scanMessage = "已索引 \(progress.indexedCount) 项 · 待扫描目录 \(progress.pendingDirectories)" }
                    })
                }.value
                scanMessage = "\(report.completed ? "扫描完成" : "已保留检查点") · \(report.indexedCount) 项 · \(String(format: "%.2f", report.elapsed)) 秒"
                if let diagnostic = report.diagnostic { status = diagnostic }
            } catch { scanMessage = error.localizedDescription }
            scanning = false; scanFlag = nil; refreshRoots(); dataRevision = UUID(); refreshSearch(resetPage: false); startNextScan()
        }
    }
    func restartScan(_ root: IndexRoot) {
        guard !scanning else { status = "请先取消当前扫描。"; return }
        do { try index?.discardScanCheckpoint(rootID: root.id); queueScan(root.id) } catch { status = error.localizedDescription }
    }
    func cancelScan() { pendingScanRoots.removeAll(); scanFlag?.cancel() }
    func pause(_ root: IndexRoot) {
        do { try index?.setPaused(rootID: root.id, paused: !root.isPaused); refreshRoots(); configureMonitor() } catch { status = error.localizedDescription }
    }
    func removeRoot(_ root: IndexRoot) {
        guard confirm(title: "移除目录索引？", message: "仅删除“\(root.displayName)”的索引授权和配置引用，原文件不变。", action: "移除索引") else { return }
        do { try index?.removeRoot(id: root.id); refreshRoots(); configureMonitor(); refreshSearch() } catch { status = error.localizedDescription }
    }
    func refreshSearch(resetPage: Bool = true) {
        if resetPage { page = 0 }
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        guard let index, fatalError == nil else { return }
        var f = filter; if section == .favorites { f.favoritesOnly = true }
        let requestedPage = page
        searching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                try Task.checkCancellation()
                let found = try await Task.detached(priority: .userInitiated) { try index.search(f, page: requestedPage, pageSize: 100) }.value
                guard !Task.isCancelled, searchGeneration == generation else { return }
                result = found; selection.formIntersection(Set(found.files.map(\.id))); searching = false
            } catch is CancellationError { } catch { guard searchGeneration == generation else { return }; status = error.localizedDescription; searching = false }
        }
    }
    var selectedFiles: [IndexedFile] { result.files.filter { selection.contains($0.id) } }
    func action(_ file: IndexedFile, allowSymbolicLink: Bool = false, _ body: (URL) throws -> Void) {
        do { try index?.withVerifiedURL(for: file, allowSymbolicLink: allowSymbolicLink, body: body) } catch { status = error.localizedDescription }
    }
    func openFile(_ file: IndexedFile) {
        action(file) { url in
            if file.isCloudPlaceholder, !confirm(title: "打开云端文件？", message: "此文件尚未完全下载。继续打开可能由系统下载内容。", action: "继续打开") { return }
            if !NSWorkspace.shared.open(url) { throw AppFailure("系统未能打开文件。") }
        }
    }
    func openSelected() { selectedFiles.forEach(openFile) }
    func revealSelected() { selectedFiles.forEach { file in action(file, allowSymbolicLink: true) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } } }
    func copySelectedPaths() {
        do {
            let urls = try selectedFiles.map { try index!.verifiedURL(for: $0, allowSymbolicLink: true) }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            status = "已复制 \(urls.count) 个核对后的路径"
        } catch { status = error.localizedDescription }
    }
    func favorite(_ file: IndexedFile) {
        do { try index?.updateAnnotations(fileID: file.id, tags: file.userTags, favorite: !file.favorite); refreshSearch(resetPage: false); dataRevision = UUID() } catch { status = error.localizedDescription }
    }
    func tag(_ file: IndexedFile) {
        guard let text = askText(title: "应用内标签", message: "用逗号分隔，仅修改搞整理索引，不改 Finder 标签。", initial: file.userTags.joined(separator: ", ")) else { return }
        let tags = text.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do { try index?.updateAnnotations(fileID: file.id, tags: tags, favorite: file.favorite); refreshSearch(resetPage: false); dataRevision = UUID() } catch { status = error.localizedDescription }
    }
    func createWorkspace() {
        guard !backingUp else { return }
        guard let name = askText(title: "新建虚拟工作区", message: "工作区组合目录、查询和收藏；不会移动原件。") else { return }
        let workspace = VirtualWorkspace(name: name); config.workspaces.append(workspace); saveConfig(); section = .workspace(workspace.id)
    }
    func renameWorkspace(_ id: UUID) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == id }), let name = askText(title: "工作区名称", message: "", initial: config.workspaces[i].name) else { return }
        config.workspaces[i].name = name; saveConfig()
    }
    func removeWorkspace(_ id: UUID) {
        guard confirm(title: "删除工作区？", message: "只删除此工作区和面板配置，原件、索引和收藏保留。", action: "删除配置") else { return }
        config.workspaces.removeAll { $0.id == id }; saveConfig(); section = .search
    }
    func addPanel(workspaceID: UUID, kind: String, root: IndexRoot? = nil) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let defaultName = root?.displayName ?? (kind == "favorites" ? "收藏" : (filter.query.isEmpty ? "已保存查询" : filter.query))
        guard let name = askText(title: "添加虚拟面板", message: "面板只保存引用和查询条件。", initial: defaultName) else { return }
        config.workspaces[i].panels.append(VirtualPanel(name: name, kind: kind, rootID: root?.id ?? filter.rootID, query: kind == "directory" ? "" : filter.query, extensionName: filter.extensionName, sort: filter.sort.rawValue, ascending: filter.ascending, filter: filter))
        saveConfig()
    }
    func editPanel(workspaceID: UUID, panelID: UUID, action: (inout VirtualPanel) -> Void) {
        guard let w = config.workspaces.firstIndex(where: { $0.id == workspaceID }), let p = config.workspaces[w].panels.firstIndex(where: { $0.id == panelID }) else { return }
        action(&config.workspaces[w].panels[p]); saveConfig()
    }
    func movePanel(workspaceID: UUID, panelID: UUID, direction: Int) {
        guard let w = config.workspaces.firstIndex(where: { $0.id == workspaceID }), let p = config.workspaces[w].panels.firstIndex(where: { $0.id == panelID }) else { return }
        let to = p + direction; guard config.workspaces[w].panels.indices.contains(to) else { return }
        config.workspaces[w].panels.swapAt(p, to); saveConfig()
    }
    func removePanel(workspaceID: UUID, panelID: UUID) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        config.workspaces[i].panels.removeAll { $0.id == panelID }; saveConfig()
    }
    func saveQuery() {
        guard !backingUp else { return }
        guard let name = askText(title: "保存当前查询", message: "保存筛选、排序和授权范围。", initial: filter.query) else { return }
        let f = filter
        config.savedQueries.append(SavedQuery(name: name, query: f.query, rootID: f.rootID, extensionName: f.extensionName, pathContains: f.pathContains, typeIdentifier: f.typeIdentifier, kind: f.kind.rawValue, minSize: f.minSize, maxSize: f.maxSize, modifiedAfter: f.modifiedAfter, modifiedBefore: f.modifiedBefore, sort: f.sort.rawValue, ascending: f.ascending, filter: f)); saveConfig()
    }
    func applyQuery(_ query: SavedQuery) {
        filter = SearchFilter(query: query.query, rootID: query.rootID, extensionName: query.extensionName, typeIdentifier: query.typeIdentifier, pathContains: query.pathContains, minSize: query.minSize, maxSize: query.maxSize, modifiedAfter: query.modifiedAfter, modifiedBefore: query.modifiedBefore, kind: SearchKind(rawValue: query.kind) ?? .all, sort: SearchSort(rawValue: query.sort) ?? .name, ascending: query.ascending)
        if let completeFilter = query.filter { filter = completeFilter }
        section = .search; refreshSearch()
    }
    func acquireSelected(_ files: [IndexedFile]) throws -> ([URL], [IndexAccessLease]) {
        guard let index else { throw AppFailure("索引不可用") }
        let leases = try Set(files.map(\.rootID)).map { try index.accessLease(rootID: $0) }
        do { return (try files.map { try index.verifiedURL(for: $0) }, leases) }
        catch { leases.forEach { $0.release() }; throw error }
    }
    func sendSelected(target: GaoExchangeDocumentTarget) async {
        do { let (urls, leases) = try acquireSelected(selectedFiles); defer { leases.forEach { $0.release() } }; await exchange?.sendDocuments(urls, target: target); status = exchange?.message ?? "" } catch { status = error.localizedDescription }
    }
    func receive(_ url: URL) async { guard !backingUp else { status = "正在备份，请稍后重新打开交接包"; return }; section = .exchange; await exchange?.receive(url); objectWillChange.send() }
    func chooseActionPackage() {
        guard !backingUp else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(importedAs: "com.gaoseries.action-package")]; p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { Task { await receive(url) } }
    }
    func routeContext() {
        guard let context = exchange?.context else { return }
        switch context.action {
        case "files.search":
            section = .search; filter = SearchFilter(query: context.query); incomingScopeNote = ""
            if let scope = context.scope {
                incomingScopeNote = "请求范围：" + scope.displayName + "。引用不等于授权。"
                filter.rootID = UUID() // Empty scope until a currently authorized identity is matched.
                do {
                    let url = try GaoActionV1.verifyReference(scope)
                    for root in roots {
                        guard let lease = try? index?.accessLease(rootID: root.id) else { continue }
                        defer { lease.release() }
                        let base = lease.url.path
                        if url.path == base || url.path.hasPrefix(base + "/") {
                            filter.rootID = root.id
                            filter.folder = url.path == base ? "" : String(url.path.dropFirst(base.count + 1))
                            incomingScopeNote = "请求范围：" + scope.displayName + " · 已匹配授权根"
                            break
                        }
                    }
                    if filter.rootID.map({ id in !roots.contains { $0.id == id } }) == true { incomingScopeNote += " 尚无匹配授权索引，请使用系统选择，或明确授权该目录。" }
                } catch { incomingScopeNote += " 原件不可用：" + error.localizedDescription }
            }
            refreshSearch()
        case "files.choose": section = .search
        case "associations.manage": section = .associations; if !context.uti.isEmpty { associations?.identifier = context.uti }; associations?.mode = "type"; associations?.refresh()
        case "files.reveal": section = .exchange
        default: status = "不支持的动作"
        }
    }
    func authorizeRequestScope() {
        guard let ref = exchange?.context?.scope else { return }; addRoot(suggested: try? GaoActionV1.verifyReference(ref)); routeContext()
    }
    func chooseForRequest() async {
        guard let context = exchange?.context, ["files.search", "files.choose"].contains(context.action) else { return }
        let p = NSOpenPanel(); p.message = "为 \(context.manifest.sourceBundleID) 选择原件。对方仍需独立核对授权。"; p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = context.multiple
        if !context.allowedUTIs.isEmpty { p.allowedContentTypes = context.allowedUTIs.compactMap { UTType($0) } }
        if let ref = context.scope { p.directoryURL = try? GaoActionV1.verifyReference(ref) }
        if p.runModal() == .OK { await exchange?.prepareSelection(p.urls) } else { await exchange?.cancelContext() }
    }
    func returnSelected() async {
        do { let (urls, leases) = try acquireSelected(selectedFiles); defer { leases.forEach { $0.release() } }; await exchange?.prepareSelection(urls) } catch { status = error.localizedDescription }
    }
    func revealRequest() async {
        guard let ref = exchange?.context?.scope else { return }
        do {
            let url = try GaoActionV1.verifyReference(ref)
            let p = NSOpenPanel(); p.title = "重新授权并核对要定位的原件"; p.directoryURL = url.deletingLastPathComponent(); p.canChooseDirectories = true; p.canChooseFiles = true
            guard p.runModal() == .OK, let chosen = p.url else { await exchange?.cancelContext(); return }
            guard chosen.standardizedFileURL == url.standardizedFileURL else { throw AppFailure("所选对象与请求原件不一致。") }
            _ = try GaoActionV1.verifyReference(ref)
            NSWorkspace.shared.activateFileViewerSelecting([chosen])
            await exchange?.finishProvider(status: .completed, provenance: ["workflowState": "revealed", "identityVerified": true])
        } catch { status = error.localizedDescription; await exchange?.finishProvider(status: .failed, provenance: ["workflowState":"failed", "reason":"referenceUnavailable"]) }
    }
    func previewMove(rename: Bool = false) async {
        guard !moving, !backingUp, !scanning, !selectedFiles.isEmpty else { return }
        do {
            releaseMoveScopes()
            let (urls, leases) = try acquireSelected(selectedFiles); moveLeases = leases
            var name: String? = nil
            let destination: URL
            if rename {
                guard urls.count == 1 else { throw AppFailure("重命名一次请选择一个文件。") }
                guard let value = askText(title: "重命名预览", message: "只支持同卷普通文件，不覆盖任何同名目标。", initial: urls[0].lastPathComponent) else { releaseMoveScopes(); return }
                name = value; destination = urls[0].deletingLastPathComponent()
            } else {
                let p = NSOpenPanel(); p.title = "选择物理移动目标"; p.message = "下一步先生成计划，不会立即移动。V1 仅支持同卷普通文件。"; p.canChooseDirectories = true; p.canChooseFiles = false
                guard p.runModal() == .OK, let value = p.url else { releaseMoveScopes(); return }
                destination = value; if value.startAccessingSecurityScopedResource() { destinationScope = value }
            }
            let authorization = try MoveAuthorization(sourceRoots: moveLeases.map(\.url), destinationRoot: destination)
            moveAuthorization = authorization
            guard let mover else { throw AppFailure("移动引擎不可用") }
            moving = true
            let plan = try await Task.detached { let p = try mover.create(sources: urls, destination: destination, rename: name, authorization: authorization); return try mover.validate(p, authorization: authorization) }.value
            movePlan = plan; moving = false; section = .moves; refreshMoveHistory()
        } catch { moving = false; releaseMoveScopes(); refreshMoveHistory(); status = error.localizedDescription }
    }
    func executeMove() async {
        guard let mover, let plan = movePlan, let auth = moveAuthorization, !moving else { return }
        guard confirm(title: "执行物理整理？", message: "计划含 \(plan.operations.count) 个普通文件。原件位置会变化。无覆盖；每项独立提交，批次并非整体原子操作。", action: "执行计划") else { return }
        moving = true
        do {
            let updated = try await Task.detached { try mover.execute(id: plan.id, confirmation: MoveConfirmation(planID: plan.id, revision: plan.revision), authorization: auth, progress: { p in Task { @MainActor [weak self = self] in self?.movePlan = p } }) }.value
            movePlan = updated; status = "计划状态：\(updated.state.rawValue)"
            for root in roots where !root.isPaused { queueScan(root.id) }
        } catch { status = error.localizedDescription; movePlan = mover.plan(id: plan.id) }
        moving = false; refreshMoveHistory(); releaseMoveScopes(); startNextScan()
    }
    func refreshMoveHistory() { moveHistory = mover?.allPlans() ?? [] }
    func cancelMove() {
        guard let plan = movePlan else { return }
        mover?.requestCancel(id: plan.id)
        if moving { status = "已请求取消，等待当前安全步骤结束。"; return }
        do { _ = try mover?.cancel(id: plan.id); refreshMoveHistory(); movePlan = nil; releaseMoveScopes() } catch { status = error.localizedDescription }
    }
    func releaseMoveScopes() { moveLeases.forEach { $0.release() }; moveLeases = []; destinationScope?.stopAccessingSecurityScopedResource(); destinationScope = nil; moveAuthorization = nil }
}

extension AppModel {
    func rollbackMove(_ plan: MovePlan) async {
        guard !moving, let mover else { return }
        guard confirm(title: "恢复原位置", message: "重新选择原位置所在的授权目录和目标目录。只有目标仍是本计划产生的同一对象且原位置没有新资料时才恢复；冲突会停止。", action: "继续授权") else { return }
        let sources = NSOpenPanel(); sources.title = "选择原来源所在目录（可多选）"; sources.canChooseFiles = false; sources.canChooseDirectories = true; sources.allowsMultipleSelection = true; sources.directoryURL = plan.operations.first?.source.deletingLastPathComponent()
        guard sources.runModal() == .OK else { return }
        let targets = NSOpenPanel(); targets.title = "选择原计划目标目录"; targets.canChooseFiles = false; targets.canChooseDirectories = true; targets.directoryURL = plan.operations.first?.destination.deletingLastPathComponent()
        guard targets.runModal() == .OK, let target = targets.url else { return }
        let scoped = (sources.urls + [target]).filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        moving = true; defer { moving = false; refreshMoveHistory(); startNextScan() }
        do {
            let auth = try MoveAuthorization(sourceRoots: sources.urls, destinationRoot: target)
            let restored = try await Task.detached { try mover.rollback(id: plan.id, authorization: auth) }.value
            movePlan = restored; status = "恢复状态：\(restored.state.rawValue)"
            for root in roots where !root.isPaused { queueScan(root.id) }
        } catch { status = error.localizedDescription }
    }
}
