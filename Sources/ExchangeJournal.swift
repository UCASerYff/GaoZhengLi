import Foundation
import Darwin

/// Single checksum-protected ledger plus independent persistent initialization marker.
/// Existing initialization + missing/corrupt ledger stops exchange; it is never recreated empty.
enum GaoExchangePhase:String,Codable {case prepared,dispatched,received,approved,executing,completed,interrupted,superseded}
struct GaoExchangeRecord:Codable,Identifiable {
    var id:String {direction+"-"+manifest.requestID.lowercased()}
    var direction:String
    var manifest:GaoActionManifest
    var manifestSHA256:String
    var packageDirectory:String
    var phase:GaoExchangePhase
    var businessStatus:GaoActionStatus?
    var replyPackageDirectory:String?
    var supersededBy:String? = nil
    var updatedAt:String
}
final class GaoExchangeJournal {
    private struct Contents:Codable {var schemaVersion=1;var generation:UInt64=0;var records:[String:GaoExchangeRecord]=[:]}
    private struct Envelope:Codable {var schemaVersion=1;var payload:Data;var sha256:String}
    private struct Marker:Codable {var schemaVersion=1;var initializedAt:String}
    private let store:ExchangeLocalData
    private let markerStore:ExchangeLocalData
    private var contents:Contents
    private var lockFD:Int32 = -1
    private static let encoder:JSONEncoder = {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return e}()
    init(dataDirectory:URL) throws {
        markerStore=ExchangeLocalData(directory:dataDirectory)
        store=ExchangeLocalData(directory:dataDirectory.appendingPathComponent("Exchange/Journal",isDirectory:true))
        if let failure=store.failure ?? markerStore.failure {throw GaoActionError.invalidPackage(failure)}
        let directory=try GaoActionFiles.openPath(store.directory,directory:true,owned:true);defer{close(directory)}
        let fd=openat(directory,"ledger.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw GaoActionError.invalidPackage("无法打开交接账本锁")}
        do {
            try GaoActionFiles.check(try GaoActionFiles.info(fd),directory:false,owned:true)
            guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw GaoActionError.invalidPackage("另一个进程正在使用交接账本；本次未处理")}
            let marker=try markerStore.load("exchange-initialized.json",as:Marker.self)
            let envelope=try store.load("ledger.json",as:Envelope.self)
            if marker != nil {
                guard marker!.schemaVersion==1,let envelope,envelope.schemaVersion==1,
                      GaoActionV1.calculateSHA256(data:envelope.payload)==envelope.sha256 else {throw GaoActionError.invalidPackage("交接账本缺失或校验失败，请保留资料并从备份恢复")}
                contents=try JSONDecoder().decode(Contents.self,from:envelope.payload)
                guard contents.schemaVersion==1,contents.records.count<=4096 else {throw GaoActionError.invalidPackage("交接账本格式或记录数量不受支持")}
            } else {
                guard envelope == nil else {throw GaoActionError.invalidPackage("交接初始化标记缺失，已有账本未被接管")}
                contents=Contents()
                // Marker first: interruption before ledger publication fails closed on next start.
                try markerStore.save(Marker(initializedAt:GaoActionV1.formatDate(Date())),name:"exchange-initialized.json")
                let payload=try Self.encoder.encode(contents)
                try store.save(Envelope(payload:payload,sha256:GaoActionV1.calculateSHA256(data:payload)),name:"ledger.json")
            }
            lockFD=fd
            for (key,record) in contents.records {
                guard key==record.id,["in","out"].contains(record.direction),UUID(uuidString:record.manifest.requestID) != nil,
                      GaoActionV1.validHash(record.manifestSHA256) else {throw GaoActionError.invalidPackage("交接账本记录身份损坏")}
            }
            var recovered=false
            for key in contents.records.keys {
                if [.approved,.executing].contains(contents.records[key]!.phase) {contents.records[key]!.phase = .interrupted;recovered=true}
            }
            if recovered {try persist()}
        } catch {close(fd);lockFD = -1;throw error}
    }
    deinit {if lockFD>=0 {flock(lockFD,LOCK_UN);close(lockFD)}}
    private func persist() throws {
        guard let marker=try markerStore.load("exchange-initialized.json",as:Marker.self),marker.schemaVersion==1 else {throw GaoActionError.invalidPackage("交接初始化标记缺失或已损坏") }
        guard contents.generation<UInt64.max else {throw GaoActionError.invalidPackage("交接账本代次溢出")}
        contents.generation += 1
        let payload=try Self.encoder.encode(contents)
        try store.save(Envelope(payload:payload,sha256:GaoActionV1.calculateSHA256(data:payload)),name:"ledger.json")
    }
    private func key(_ id:String,_ direction:String)->String {direction+"-"+id.lowercased()}
    func record(_ id:String,direction:String)->GaoExchangeRecord? {contents.records[key(id,direction)]}
    func history()->[GaoExchangeRecord] {contents.records.values.sorted{$0.updatedAt>$1.updatedAt}}
    /// Returns the old record for exact duplicates; a reused UUID/nonce cannot create a new operation.
    func preflight(_ m:GaoActionManifest,digest:String) throws -> GaoExchangeRecord? {
        if let old=record(m.requestID,direction:"in") {
            guard old.manifestSHA256==digest,old.manifest==m else {throw GaoActionError.invalidPackage("相同 UUID 的内容不同，已拒绝")};return old
        }
        guard !contents.records.values.contains(where:{$0.direction=="in" && $0.manifest.nonce==m.nonce}) else {throw GaoActionError.invalidPackage("nonce 已在其他请求使用")}
        if m.kind == .request {
            guard ["files.search","files.choose","files.reveal","associations.manage"].contains(m.action),m.targetBundleID==GaoActionV1.ownBundleID else {throw GaoActionError.invalidPackage("本应用不提供该动作")}
        } else {
            guard let reply=m.inReplyTo,let original=record(reply,direction:"out"),original.manifest.kind == .request,
                  original.manifest.action==m.action,original.manifest.targetBundleID==m.sourceBundleID,
                  original.manifest.sourceBundleID==m.targetBundleID,original.businessStatus==nil || original.businessStatus == .pending
            else {throw GaoActionError.invalidPackage("结果没有匹配的未完成原请求")}
        }
        return nil
    }
    func receive(_ package:GaoActionReceivedPackage) throws {
        guard try preflight(package.manifest,digest:package.manifestSHA256)==nil else {return}
        guard contents.records.count<4096 else {throw GaoActionError.sizeExceeded("交接账本已达上限，请保留备份并人工整理")}
        let r=GaoExchangeRecord(direction:"in",manifest:package.manifest,manifestSHA256:package.manifestSHA256,packageDirectory:package.directory.path,phase:.received,businessStatus:package.manifest.status,updatedAt:GaoActionV1.formatDate(Date()))
        contents.records[r.id]=r;try persist()
    }
    func prepare(_ m:GaoActionManifest,digest:String,package:URL) throws {
        guard record(m.requestID,direction:"out")==nil,contents.records.count<4096 else {throw GaoActionError.duplicateRequest(m.requestID)}
        let r=GaoExchangeRecord(direction:"out",manifest:m,manifestSHA256:digest,packageDirectory:package.path,phase:.prepared,businessStatus:m.status,updatedAt:GaoActionV1.formatDate(Date()))
        contents.records[r.id]=r;try persist()
    }
    /// Atomically retire an expired/failed result envelope and register its fresh replacement.
    /// The business result must be identical; only UUID, nonce and its 120-second clock change.
    func replacePreparedResult(_ oldID:String,with m:GaoActionManifest,digest:String,package:URL) throws {
        let k=key(oldID,"out")
        guard var old=contents.records[k],old.manifest.kind == .result,[.prepared,.interrupted].contains(old.phase),
              m.kind == .result,record(m.requestID,direction:"out")==nil,contents.records.count<4096 else {throw GaoActionError.invalidPackage("回执无法安全更新有效期")}
        var oldSemantic=old.manifest,newSemantic=m
        oldSemantic.requestID="";newSemantic.requestID=""
        oldSemantic.nonce="";newSemantic.nonce=""
        oldSemantic.createdAt="";newSemantic.createdAt=""
        oldSemantic.expiresAt="";newSemantic.expiresAt=""
        guard oldSemantic==newSemantic else {throw GaoActionError.invalidPackage("更新有效期不得改变业务结果")}
        old.phase = .superseded;old.supersededBy=m.requestID;old.updatedAt=GaoActionV1.formatDate(Date())
        let replacement=GaoExchangeRecord(direction:"out",manifest:m,manifestSHA256:digest,packageDirectory:package.path,phase:.prepared,businessStatus:m.status,updatedAt:GaoActionV1.formatDate(Date()))
        contents.records[k]=old;contents.records[replacement.id]=replacement;try persist()
    }
    func transition(_ id:String,direction:String,to:GaoExchangePhase) throws {
        let k=key(id,direction);guard var r=contents.records[k] else {throw GaoActionError.invalidPackage("交接记录缺失")}
        let allowed:[GaoExchangePhase:Set<GaoExchangePhase>]=[.prepared:[.dispatched],.dispatched:[.interrupted],.received:[.approved],.approved:[.executing],.executing:[.completed,.interrupted],.completed:[],.interrupted:[]]
        guard allowed[r.phase]?.contains(to)==true else {throw GaoActionError.invalidPackage("交接状态不允许重复执行")}
        r.phase=to;r.updatedAt=GaoActionV1.formatDate(Date());contents.records[k]=r;try persist()
    }
    func completeRequest(_ id:String,status:GaoActionStatus,reply:URL) throws {
        let k=key(id,"in");guard var r=contents.records[k],r.phase == .executing || r.phase == .approved else {throw GaoActionError.invalidPackage("请求不处于用户处理阶段")}
        r.phase = .completed;r.businessStatus=status;r.replyPackageDirectory=reply.path;r.updatedAt=GaoActionV1.formatDate(Date());contents.records[k]=r;try persist()
    }
    func acceptResult(_ id:String) throws {
        guard let r=record(id,direction:"in"),r.phase == .received,let reply=r.manifest.inReplyTo,var original=record(reply,direction:"out") else {throw GaoActionError.invalidPackage("结果未处于待确认状态")}
        try transition(id,direction:"in",to:.approved);try transition(id,direction:"in",to:.executing)
        original.businessStatus=r.manifest.status
        if r.manifest.status != .pending {original.phase = .completed}
        original.updatedAt=GaoActionV1.formatDate(Date());contents.records[original.id]=original;try persist()
        try transition(id,direction:"in",to:.completed)
    }
}
