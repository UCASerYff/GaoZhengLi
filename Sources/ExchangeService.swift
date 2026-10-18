import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GaoExchangeReview:Identifiable {
    let package:GaoActionReceivedPackage
    var id:String {package.manifest.requestID}
    var manifest:GaoActionManifest {package.manifest}
    var summary:String {
        "动作：\(manifest.action)\n来源声明：\(manifest.sourceBundleID)\n\(manifest.kind == .result ? "对方报告："+(manifest.status?.rawValue ?? "未知") : "等待你确认处理")\n附件：\(manifest.items.count)，引用：\(manifest.references.count)\n来源声明和 nonce 不证明发送者身份。引用不是访问授权；只在你确认后处理。"
    }
}
struct GaoExchangeContext:Identifiable {
    let manifest:GaoActionManifest
    var id:String {manifest.requestID}
    var requestID:String {id}
    var action:String {manifest.action}
    var query:String {manifest.parameters["query"]?.value as? String ?? ""}
    var uti:String {manifest.parameters["uti"]?.value as? String ?? ""}
    var scope:GaoActionReference? {manifest.references.first}
    var allowedUTIs:[String] {manifest.parameters["allowedUTIs"]?.value as? [String] ?? []}
    var multiple:Bool {manifest.parameters["multiple"]?.value as? Bool ?? true}
}
enum GaoExchangeDocumentTarget:CaseIterable {
    case files,research
    var bundleID:String {self == .files ? "com.gaoseries.GaoWenJian" : "com.academic-achievement.manager"}
    var action:String {self == .files ? "documents.open" : "research.importDocuments"}
}

@MainActor final class GaoExchangeService:ObservableObject {
    let dataDirectory:URL
    @Published private(set) var review:GaoExchangeReview?
    @Published private(set) var context:GaoExchangeContext?
    @Published private(set) var preparedResult:URL?
    @Published private(set) var records:[GaoExchangeRecord]=[]
    @Published private(set) var message=""
    @Published private(set) var error:String?
    @Published private(set) var busy=false
    private var retained:[String:GaoActionReceivedPackage]=[:]
    private var journalCache:GaoExchangeJournal?
    var outgoingDirectory:URL {dataDirectory.appendingPathComponent("Exchange/Outgoing",isDirectory:true)}
    var incomingDirectory:URL {dataDirectory.appendingPathComponent("Exchange/Incoming",isDirectory:true)}
    init(dataDirectory:URL) {self.dataDirectory=dataDirectory}
    private func journal() throws -> GaoExchangeJournal {
        if let journalCache {return journalCache}
        let result=try GaoExchangeJournal(dataDirectory:dataDirectory);journalCache=result;return result
    }
    private func refresh() {if let journalCache {records=journalCache.history()}}
    private func run(_ action:() async throws -> Void) async {
        guard !busy else {message="正在处理上一个交接动作";return};busy=true;error=nil
        defer{busy=false;refresh()}
        do {try await action()}catch{self.error=error.localizedDescription;message=error.localizedDescription}
    }
    func loadHistory() {do{_ = try journal();refresh()}catch{self.error=error.localizedDescription}}
    func receive(_ url:URL) async {
        await run {
            guard review==nil,context==nil else {throw GaoActionError.invalidPackage("请先完成或取消当前交接，再重新打开该包")}
            let header=try await Task.detached {try GaoActionV1.inspectManifest(at:url,expectedTarget:GaoActionV1.ownBundleID)}.value
            if let old=try journal().preflight(header.manifest,digest:header.digest) {
                message="该请求已记录：\(old.phase.rawValue) / \(old.businessStatus?.rawValue ?? "等待处理")；未重复执行"
                return
            }
            let destination=incomingDirectory
            let staged=try await Task.detached {try GaoActionV1.stagePackage(at:url,in:destination)}.value
            guard staged.manifestSHA256==header.digest else {throw GaoActionError.invalidPackage("复制前后请求改变，拒绝处理")}
            try journal().receive(staged);retained[staged.manifest.requestID]=staged;review=GaoExchangeReview(package:staged)
            message="交接包已复制并校验，等待你核对"
        }
    }
    func resumeReview(_ record:GaoExchangeRecord) async {
        await run {
            guard review==nil,context==nil,record.direction=="in",record.phase == .received,
                  let current=try journal().record(record.manifest.requestID,direction:"in"),current.phase == .received
            else {throw GaoActionError.invalidPackage("该交接不处于待核对状态")}
            let p=GaoActionReceivedPackage(manifest:current.manifest,directory:URL(fileURLWithPath:current.packageDirectory),files:current.manifest.items.map{URL(fileURLWithPath:current.packageDirectory).appendingPathComponent("payload/"+GaoActionV1.payloadRelativePath($0.relativePath))},manifestSHA256:current.manifestSHA256)
            try await Task.detached {try GaoActionV1.verifyRetainedPackage(p)}.value
            retained[current.manifest.requestID]=p;review=GaoExchangeReview(package:p)
        }
    }
    func acceptReview() async {
        await run {
            guard let review else {throw GaoActionError.invalidPackage("没有待核对交接")}
            let package=review.package
            try await Task.detached {try GaoActionV1.verifyRetainedPackage(package)}.value
            if package.manifest.kind == .result {
                try journal().acceptResult(package.manifest.requestID);self.review=nil
                message="已核对结果；对方报告 \(package.manifest.status!.rawValue)。原件未覆盖"
            } else {
                try journal().transition(package.manifest.requestID,direction:"in",to:.approved)
                try journal().transition(package.manifest.requestID,direction:"in",to:.executing)
                context=GaoExchangeContext(manifest:package.manifest);self.review=nil
                message="已接受请求，请在对应界面处理；尚未返回完成结果"
            }
        }
    }
    func rejectReview() async {
        guard let review else {return}
        if review.manifest.kind == .result {self.review=nil;message="结果保留待核对；可在交接记录继续";return}
        await run {
            let p=review.package;try await Task.detached {try GaoActionV1.verifyRetainedPackage(p)}.value
            try journal().transition(p.manifest.requestID,direction:"in",to:.approved)
            context=GaoExchangeContext(manifest:p.manifest);self.review=nil
            try await prepareResult(status:.cancelled,provenance:["workflowState":"cancelled","reason":"userDeclined"])
        }
    }
    /// Called solely by the user's Send Selected action; enumerating search results never sends them.
    func prepareSelection(_ urls:[URL]) async {
        await run {
            guard let c=context,["files.search","files.choose"].contains(c.action),!urls.isEmpty,urls.count<=256,c.multiple || urls.count==1 else {throw GaoActionError.invalidPackage("请选择符合数量要求的文件；取消请使用取消请求")}
            let requested=Set(c.allowedUTIs),scope=c.scope
            let references=try await Task.detached {() throws -> [GaoActionReference] in
                let scopedURL=try scope.map(GaoActionV1.verifyReference)
                return try urls.enumerated().map {index,url in
                    let access=url.startAccessingSecurityScopedResource();defer{if access {url.stopAccessingSecurityScopedResource()}}
                    let reference=try GaoActionV1.reference(for:url,id:"selected-\(index+1)")
                    guard reference.kind == .file else {throw GaoActionError.invalidPackage("文件选择仅发送普通原件；目录、应用包和链接不发送")}
                    let actual=try GaoActionV1.verifyReference(reference)
                    if let scopedURL {guard actual.path.hasPrefix(scopedURL.path+"/") else {throw GaoActionError.invalidPackage("所选文件不在请求的目录范围")}}
                    if !requested.isEmpty {
                        let type=try actual.resourceValues(forKeys:[.contentTypeKey]).contentType ?? UTType(filenameExtension:actual.pathExtension) ?? .data
                        guard requested.contains(where:{UTType($0).map{type.conforms(to:$0)} == true}) else {throw GaoActionError.invalidPackage("所选文件类型不符合请求")}
                    }
                    return reference
                }
            }.value
            guard Set(references.map{$0.fileURL!}).count==references.count else {throw GaoActionError.invalidPackage("请移除重复文件")}
            try await prepareResult(status:.completed,provenance:["workflowState":"selected","selectionCount":references.count,"accessRequiresReceiverVerification":true],references:references)
        }
    }
    func finishProvider(status:GaoActionStatus,provenance:[String:Any]) async {
        await run {
            guard let c=context,["files.reveal","associations.manage"].contains(c.action) else {throw GaoActionError.invalidPackage("没有相应业务请求")}
            if status == .completed {
                if c.action == "files.reveal" {guard provenance["workflowState"] as? String == "revealed" else {throw GaoActionError.invalidPackage("定位完成需要实际定位回执")}}
                else {guard provenance["workflowState"] as? String == "changed",provenance["readBackVerified"] as? Bool == true,
                           let actualUTI=provenance["uti"] as? String,UTType(actualUTI) != nil,c.uti.isEmpty || actualUTI==c.uti else {throw GaoActionError.invalidPackage("关联完成需要系统读回校验")}}
            }
            try await prepareResult(status:status,provenance:provenance)
        }
    }
    func cancelContext() async {await run{try await prepareResult(status:.cancelled,provenance:["workflowState":"cancelled"])}}
    private func prepareResult(status:GaoActionStatus,provenance:[String:Any],references:[GaoActionReference]=[]) async throws {
        guard let c=context else {throw GaoActionError.invalidPackage("没有用户接受的请求")}
        let outgoing=outgoingDirectory
        let url=try await Task.detached {try GaoActionV1.createResultPackage(in:outgoing,request:c.manifest,status:status,provenance:provenance,references:references)}.value
        let h=try GaoActionV1.inspectManifest(at:url)
        try journal().prepare(h.manifest,digest:h.digest,package:url)
        try journal().completeRequest(c.requestID,status:status,reply:url)
        preparedResult=url;context=nil;message="已生成 \(status.rawValue) 回执；点击发送结果才交给原应用"
    }
    /// Explicit Send Result UI action. LaunchServices delivery is distinct from business completion.
    func sendPreparedResult() async {
        await run {
            guard var url=preparedResult else {throw GaoActionError.invalidPackage("没有待发送结果")}
            try await dispatchResult(&url)
            preparedResult=nil;message="结果已递交原应用，等待对方核对；递交不表示对方已完成业务"
        }
    }
    func prepareToSend(_ record:GaoExchangeRecord) {
        guard record.direction=="out",record.manifest.kind == .result,[.prepared,.interrupted].contains(record.phase) else {return}
        preparedResult=URL(fileURLWithPath:record.packageDirectory);message="回执已保留；发送前会重新校验"
    }
    private func dispatchResult(_ url:inout URL) async throws {
        guard let r=try journal().history().first(where:{$0.direction=="out" && $0.packageDirectory==url.path}),r.manifest.kind == .result,[.prepared,.interrupted].contains(r.phase) else {throw GaoActionError.invalidPackage("结果已发送或记录缺失")}
        let p=GaoActionReceivedPackage(manifest:r.manifest,directory:url,files:[],manifestSHA256:r.manifestSHA256)
        try await Task.detached {try GaoActionV1.verifyRetainedPackage(p)}.value
        if r.phase == .interrupted || GaoActionV1.parseDate(r.manifest.expiresAt)! <= Date() {
            guard let reply=r.manifest.inReplyTo,let original=try journal().record(reply,direction:"in") else {throw GaoActionError.invalidPackage("结果原请求缺失")}
            let outgoing=outgoingDirectory,m=r.manifest
            url=try await Task.detached {try GaoActionV1.createResultPackage(in:outgoing,request:original.manifest,status:m.status!,provenance:m.provenance!.mapValues(\.value),references:m.references,errorCode:m.errorCode)}.value
            let h=try GaoActionV1.inspectManifest(at:url);try journal().replacePreparedResult(r.manifest.requestID,with:h.manifest,digest:h.digest,package:url)
            preparedResult=url
        }
        let h=try GaoActionV1.inspectManifest(at:url)
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:h.manifest.targetBundleID),Bundle(url:app)?.bundleIdentifier==h.manifest.targetBundleID else {throw GaoActionError.providerNotReady("原应用未安装，结果保留在私有目录")}
        try await dispatch(url,app:app,manifest:h.manifest)
    }
    func providerAvailability(_ target:GaoExchangeDocumentTarget)->String? {
        do{_ = try provider(target);return nil}catch{return error.localizedDescription}
    }
    private func provider(_ target:GaoExchangeDocumentTarget) throws -> URL {
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:target.bundleID) else {throw GaoActionError.providerNotReady("目标应用未安装；本次未发送")}
        try GaoActionProviderCapabilities.load(appURL:app,bundleID:target.bundleID).require(action:target.action,parameters:[:],items:true,references:false);return app
    }
    /// Explicit user-send copies. No cross-process bookmarks are exported.
    func sendDocuments(_ urls:[URL],target:GaoExchangeDocumentTarget) async {
        await run {
            let app=try provider(target),outgoing=outgoingDirectory
            guard !urls.isEmpty else {throw GaoActionError.invalidPackage("请先选择原件")}
            let url=try await Task.detached {try GaoActionV1.createRequestPackage(in:outgoing,action:target.action,targetBundleID:target.bundleID,inputFiles:urls)}.value
            let h=try GaoActionV1.inspectManifest(at:url)
            try GaoActionProviderCapabilities.load(appURL:app,bundleID:target.bundleID).requireManifest(h.manifest)
            try journal().prepare(h.manifest,digest:h.digest,package:url)
            try await dispatch(url,app:app,manifest:h.manifest)
            message="已递交文档副本，等待目标应用确认和结果；原件未改变"
        }
    }
    private func dispatch(_ package:URL,app:URL,manifest:GaoActionManifest) async throws {
        guard Bundle(url:app)?.bundleIdentifier==manifest.targetBundleID else {throw GaoActionError.providerNotReady("目标应用身份改变")}
        let header=try GaoActionV1.inspectManifest(at:package)
        guard let record=try journal().record(manifest.requestID,direction:"out"),record.manifestSHA256==header.digest else {throw GaoActionError.invalidPackage("发件包已改变")}
        if manifest.kind == .request {try GaoActionProviderCapabilities.load(appURL:app,bundleID:manifest.targetBundleID).requireManifest(manifest)}
        let config=NSWorkspace.OpenConfiguration();config.activates=true;config.allowsRunningApplicationSubstitution=false
        try journal().transition(manifest.requestID,direction:"out",to:.dispatched)
        do {
            _ = try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<NSRunningApplication,Error>) in
                NSWorkspace.shared.open([package],withApplicationAt:app,configuration:config){app,error in
                    if let error{continuation.resume(throwing:error)}else if let app{continuation.resume(returning:app)}else{continuation.resume(throwing:GaoActionError.providerNotReady("系统未能递交交接包"))}
                }
            }
        } catch {
            try journal().transition(manifest.requestID,direction:"out",to:.interrupted)
            throw GaoActionError.providerNotReady("递交未完成，包与记录已保留。重新发送请求前请先核对目标应用，避免重复业务："+error.localizedDescription)
        }
    }
}
