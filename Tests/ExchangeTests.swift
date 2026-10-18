import AppKit
import Foundation
import CryptoKit
import Darwin

private enum TestFailure:Error {case assertion(String)}
@main struct ExchangeTests {
    static var passed=0
    static let fm=FileManager.default
    static func check(_ condition:Bool,_ message:String) throws {guard condition else {throw TestFailure.assertion(message)};passed += 1}
    static func rejects(_ message:String,_ block:() throws -> Void) throws {
        do {try block()}catch {passed += 1;return};throw TestFailure.assertion("expected rejection: "+message)
    }
    static func change(_ url:URL,_ edit:(inout [String:Any])->Void) throws {
        var object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];edit(&object)
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url)
    }
    static func privateDir(_ url:URL) throws {let fd=try GaoActionFiles.privateDirectory(url);close(fd)}
    @MainActor static func main() async throws {
        let root=fm.temporaryDirectory.appendingPathComponent("GaoZhengLi-ExchangeTests-"+UUID().uuidString,isDirectory:true)
        try privateDir(root);defer{try? fm.removeItem(at:root)}
        let source=root.appendingPathComponent("原创 中文 é \".txt")
        try Data("原创交接夹具\n第二行".utf8).write(to:source);chmod(source.path,0o600)
        let now=Date(),out=root.appendingPathComponent("Exchange/Outgoing")
        let chooseURL=try GaoActionV1.createRequestPackage(in:out,action:"files.choose",targetBundleID:GaoActionV1.ownBundleID,sourceBundleID:"com.gaoseries.GaoWenJian",parameters:["multiple":true],now:now)
        let choose=try GaoActionV1.inspectManifest(at:chooseURL,now:now)
        var ids=Set<String>();_ = try GaoActionV1.validatePackageDirectory(at:chooseURL,now:now,knownIDs:&ids,expectedTarget:GaoActionV1.ownBundleID)
        try check(ids.contains(choose.manifest.requestID.lowercased()),"valid files.choose")
        try rejects("duplicate validator UUID"){_ = try GaoActionV1.validatePackageDirectory(at:chooseURL,now:now,knownIDs:&ids)}
        let original=try GaoActionV1.reference(for:source,id:"selected-1")
        try check(try GaoActionV1.verifyReference(original)==GaoActionFiles.normalized(source),"reference independent identity")
        let result=try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.completed,provenance:["workflowState":"selected","selectionCount":1],references:[original],now:now)
        let selected=try GaoActionV1.inspectManifest(at:result,now:now)
        try check(selected.manifest.requestID != choose.manifest.requestID && selected.manifest.nonce != choose.manifest.nonce,"results get new UUID+nonce")
        try check(selected.manifest.inReplyTo==choose.manifest.requestID && selected.manifest.references.count==1,"selection references result")
        let cancel=try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.cancelled,provenance:["workflowState":"cancelled"],now:now)
        try check(try GaoActionV1.inspectManifest(at:cancel,now:now).manifest.references.isEmpty,"cancel returns no selection")
        try rejects("cancel cannot carry selection"){_ = try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.cancelled,provenance:["workflowState":"cancelled"],references:[original],now:now)}
        var malformed=choose.manifest;malformed.nonce="AA=="
        try rejects("bad nonce"){try GaoActionV1.validateManifest(malformed,now:now)}
        malformed=choose.manifest;malformed.expiresAt=GaoActionV1.formatDate(now.addingTimeInterval(121))
        try rejects("TTL >120"){try GaoActionV1.validateManifest(malformed,now:now)}
        try rejects("expired"){try GaoActionV1.validateManifest(choose.manifest,now:now.addingTimeInterval(121))}
        malformed=choose.manifest;malformed.schemaVersion=2
        try rejects("schema v2"){try GaoActionV1.validateManifest(malformed,now:now)}
        malformed=choose.manifest;malformed.action="shell.run"
        try rejects("unknown action"){try GaoActionV1.validateManifest(malformed,now:now)}
        malformed=choose.manifest;malformed.parameters["setDefault"]=GaoActionAnyCodable(true)
        try rejects("unlisted parameter"){try GaoActionV1.validateManifest(malformed,now:now)}
        try rejects("duplicate JSON keys"){_ = try GaoActionV1.decodeManifest(Data("{\"kind\":\"request\",\"kind\":\"result\"}".utf8))}
        try rejects("escaped duplicate JSON keys"){_ = try GaoActionV1.decodeManifest(Data("{\"kind\":\"request\",\"k\\u0069nd\":\"result\"}".utf8))}
        for path in ["../escape","/absolute","payload/../../escape","a//b","a\\b","a/./b"] {try rejects("path "+path){try GaoActionV1.safeRelativePath(path)}}
        let docs=try GaoActionV1.createRequestPackage(in:out,action:"documents.open",targetBundleID:"com.gaoseries.GaoWenJian",inputFiles:[source],now:now)
        var docIDs=Set<String>();let docManifest=try GaoActionV1.validatePackageDirectory(at:docs,now:now,knownIDs:&docIDs)
        try check(docManifest.items.first?.sha256==GaoActionV1.calculateSHA256(data:Data("原创交接夹具\n第二行".utf8)),"copy preserves exact bytes")
        let staged=try GaoActionV1.stagePackage(at:docs,in:root.appendingPathComponent("Staged/Incoming"),now:now,expectedTarget:"com.gaoseries.GaoWenJian")
        try GaoActionV1.verifyRetainedPackage(staged);passed += 1
        try Data("篡改".utf8).write(to:staged.files[0])
        try rejects("retained payload changed after review"){try GaoActionV1.verifyRetainedPackage(staged)}
        let payload=docs.appendingPathComponent("payload/"+docManifest.items[0].relativePath)
        try fm.removeItem(at:payload);try fm.createSymbolicLink(at:payload,withDestinationURL:source)
        try rejects("payload symlink"){var seen=Set<String>();_ = try GaoActionV1.validatePackageDirectory(at:docs,now:now,knownIDs:&seen)}
        try fm.removeItem(at:payload);try fm.linkItem(at:source,to:payload)
        try rejects("payload hard link"){var seen=Set<String>();_ = try GaoActionV1.validatePackageDirectory(at:docs,now:now,knownIDs:&seen)}
        try fm.removeItem(at:payload)
        let evilParent=root.appendingPathComponent("linked-parent");try fm.createSymbolicLink(at:evilParent,withDestinationURL:out)
        try rejects("symlink in parent path"){_ = try GaoActionV1.inspectManifest(at:evilParent.appendingPathComponent(chooseURL.lastPathComponent),now:now)}
        try rejects("retained storage budget"){try GaoActionStorageBudget.check(exchange:out.deletingLastPathComponent(),additionalBytes:100,maximumBytes:1,maximumCount:128)}
        let research=try GaoActionV1.createRequestPackage(in:out,action:"research.importDocuments",targetBundleID:"com.academic-achievement.manager",inputFiles:[source],now:now)
        let researchManifest=try GaoActionV1.inspectManifest(at:research,now:now).manifest
        try check(researchManifest.items[0].relativePath.hasPrefix("payload/"),"real research parser path spelling")
        var researchIDs=Set<String>();_ = try GaoActionV1.validatePackageDirectory(at:research,now:now,knownIDs:&researchIDs)
        passed += 1
        // Durable identity, interruption recovery, result match, and fail-closed ledger behavior.
        let dataDir=root.appendingPathComponent("Data")
        var journal:GaoExchangeJournal?=try GaoExchangeJournal(dataDirectory:dataDir)
        let received=try GaoActionV1.stagePackage(at:chooseURL,in:root.appendingPathComponent("JournalStage/Incoming"),now:now)
        try journal!.receive(received)
        try check(try journal!.preflight(received.manifest,digest:received.manifestSHA256) != nil,"same UUID same content duplicate")
        var different=received.manifest;different.parameters["multiple"]=GaoActionAnyCodable(false)
        try rejects("same UUID differing content"){_ = try journal!.preflight(different,digest:String(repeating:"a",count:64))}
        different=received.manifest;different.requestID=UUID().uuidString
        try rejects("nonce reused across UUIDs"){_ = try journal!.preflight(different,digest:String(repeating:"b",count:64))}
        try journal!.transition(choose.manifest.requestID,direction:"in",to:.approved)
        try journal!.transition(choose.manifest.requestID,direction:"in",to:.executing)
        journal=nil
        journal=try GaoExchangeJournal(dataDirectory:dataDir)
        try check(journal!.record(choose.manifest.requestID,direction:"in")?.phase == .interrupted,"restart marks executing interrupted")
        try rejects("interrupted request cannot replay"){try journal!.transition(choose.manifest.requestID,direction:"in",to:.executing)}
        let requestH=try GaoActionV1.inspectManifest(at:research,now:now)
        try journal!.prepare(requestH.manifest,digest:requestH.digest,package:research)
        let researchReply=try GaoActionV1.createResultPackage(in:out,request:requestH.manifest,status:.pending,provenance:["workflowState":"awaitingUser"],now:now)
        let replyH=try GaoActionV1.inspectManifest(at:researchReply,now:now)
        try check(try journal!.preflight(replyH.manifest,digest:replyH.digest)==nil,"matching pending result")
        var wrong=replyH.manifest;wrong.sourceBundleID="com.invalid.provider"
        try rejects("result wrong provider"){_ = try journal!.preflight(wrong,digest:replyH.digest)}
        wrong=replyH.manifest;wrong.inReplyTo=UUID().uuidString
        try rejects("result unmatched request"){_ = try journal!.preflight(wrong,digest:replyH.digest)}
        let receivedReply=try GaoActionV1.stagePackage(at:researchReply,in:root.appendingPathComponent("ReplyStage/Incoming"),now:now)
        try journal!.receive(receivedReply);try journal!.acceptResult(receivedReply.manifest.requestID)
        try check(journal!.record(requestH.manifest.requestID,direction:"out")?.businessStatus == .pending,"pending stays pending")
        let finalReply=try GaoActionV1.createResultPackage(in:out,request:requestH.manifest,status:.partial,provenance:["workflowState":"partial"],now:now)
        let finalH=try GaoActionV1.inspectManifest(at:finalReply,now:now)
        let receivedFinal=try GaoActionV1.stagePackage(at:finalReply,in:root.appendingPathComponent("FinalStage/Incoming"),now:now)
        try journal!.receive(receivedFinal);try journal!.acceptResult(finalH.manifest.requestID)
        try check(journal!.record(requestH.manifest.requestID,direction:"out")?.businessStatus == .partial,"partial stays partial")
        wrong=finalH.manifest;wrong.requestID=UUID().uuidString
        try rejects("cannot replace terminal result"){_ = try journal!.preflight(wrong,digest:finalH.digest)}
        try journal!.prepare(selected.manifest,digest:selected.digest,package:result)
        let renewedResult=try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.completed,provenance:["workflowState":"selected","selectionCount":1],references:[original],now:now)
        let renewedHeader=try GaoActionV1.inspectManifest(at:renewedResult,now:now)
        try journal!.replacePreparedResult(selected.manifest.requestID,with:renewedHeader.manifest,digest:renewedHeader.digest,package:renewedResult)
        try check(journal!.record(selected.manifest.requestID,direction:"out")?.phase == .superseded,"old envelope atomically retired on renewal")
        try check(journal!.record(renewedHeader.manifest.requestID,direction:"out")?.phase == .prepared,"renewal stays prepared until user dispatch")
        try rejects("superseded receipt cannot dispatch"){try journal!.transition(selected.manifest.requestID,direction:"out",to:.dispatched)}
        let changedResult=try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.cancelled,provenance:["workflowState":"cancelled"],now:now)
        let changedHeader=try GaoActionV1.inspectManifest(at:changedResult,now:now)
        try rejects("renewal cannot change business semantics"){try journal!.replacePreparedResult(renewedHeader.manifest.requestID,with:changedHeader.manifest,digest:changedHeader.digest,package:changedResult)}
        journal=nil
        let ledger=dataDir.appendingPathComponent("Exchange/Journal/ledger.json"),saved=try Data(contentsOf:ledger)
        try fm.removeItem(at:ledger)
        try rejects("initialized but missing ledger"){_ = try GaoExchangeJournal(dataDirectory:dataDir)}
        try saved.write(to:ledger);try Data("corrupt".utf8).write(to:ledger)
        try rejects("corrupt ledger"){_ = try GaoExchangeJournal(dataDirectory:dataDir)}
        try saved.write(to:ledger)
        try change(ledger){$0["sha256"]=String(repeating:"f",count:64)}
        try rejects("ledger checksum"){_ = try GaoExchangeJournal(dataDirectory:dataDir)}
        try saved.write(to:ledger)
        try change(ledger){$0["schemaVersion"]=2}
        try rejects("ledger future schema"){_ = try GaoExchangeJournal(dataDirectory:dataDir)}
        // Capability checks read actual installed manifests and never launch their apps.
        for (path,bundle,action) in [("/Applications/搞文件.app","com.gaoseries.GaoWenJian","documents.open"),("/Applications/搞研究.app","com.academic-achievement.manager","research.importDocuments")] {
            let caps=try GaoActionProviderCapabilities.load(appURL:URL(fileURLWithPath:path),bundleID:bundle)
            try caps.require(action:action,parameters:[:],items:true,references:false);passed += 1
        }
        let mock=root.appendingPathComponent("Provider.app"),resources=mock.appendingPathComponent("Contents/Resources")
        try privateDir(resources)
        let info:[String:Any] = ["CFBundleIdentifier":GaoActionV1.ownBundleID,"CFBundleShortVersionString":"1.00","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:mock.appendingPathComponent("Contents/Info.plist"))
        let capsURL=resources.appendingPathComponent("GaoCapabilities.json")
        let capSource=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Resources/GaoCapabilities.json")
        let fallback=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("搞整理/Resources/GaoCapabilities.json")
        try Data(contentsOf:fm.fileExists(atPath:capSource.path) ? capSource : fallback).write(to:capsURL)
        let caps=try GaoActionProviderCapabilities.load(appURL:mock,bundleID:GaoActionV1.ownBundleID)
        try caps.require(action:"files.choose",parameters:["multiple":true],items:false,references:false);passed += 1
        try rejects("capabilities parameter mismatch"){try caps.require(action:"files.choose",parameters:["mode":"copy"],items:false,references:false)}
        try rejects("capabilities payload forbidden"){try caps.require(action:"files.choose",parameters:[:],items:true,references:false)}
        try change(capsURL){$0["appVersion"]="9.99"}
        try rejects("capabilities version mismatch"){_ = try GaoActionProviderCapabilities.load(appURL:mock,bundleID:GaoActionV1.ownBundleID)}
        try fm.removeItem(at:capsURL)
        try rejects("capabilities missing"){_ = try GaoActionProviderCapabilities.load(appURL:mock,bundleID:GaoActionV1.ownBundleID)}
        // Provider service never chooses/sends without the two explicit UI actions.
        let service=GaoExchangeService(dataDirectory:root.appendingPathComponent("ServiceData"))
        await service.receive(chooseURL)
        try check(service.review != nil && service.context==nil && service.preparedResult==nil,"receipt awaits user review")
        await service.acceptReview()
        try check(service.context?.action=="files.choose" && service.preparedResult==nil,"accepted request awaits user selection")
        await service.prepareSelection([source])
        try check(service.preparedResult != nil && service.context==nil,"user selection prepares unsent result")
        let prepared=try GaoActionV1.inspectManifest(at:service.preparedResult!)
        try check(prepared.manifest.references.count==1 && prepared.manifest.items.isEmpty,"service selection sends only references")
        // Optional output retained for separately compiling the unmodified sibling parsers.
        if let i=CommandLine.arguments.firstIndex(of:"--fixtures"),CommandLine.arguments.count>i+1 {
            let destination=URL(fileURLWithPath:CommandLine.arguments[i+1]);try privateDir(destination)
            let fixtureFile=destination.appendingPathComponent("原创选择.txt")
            try Data("独立选择原件夹具".utf8).write(to:fixtureFile)
            let fixtureRef=try GaoActionV1.reference(for:fixtureFile,id:"selected-1")
            let fixtureResult=try GaoActionV1.createResultPackage(in:out,request:choose.manifest,status:.completed,provenance:["workflowState":"selected","selectionCount":1],references:[fixtureRef])
            let researchChoose=try GaoActionV1.createRequestPackage(in:out,action:"files.choose",targetBundleID:GaoActionV1.ownBundleID,sourceBundleID:"com.academic-achievement.manager",parameters:["multiple":true])
            let researchChooseManifest=try GaoActionV1.inspectManifest(at:researchChoose).manifest
            let researchChoiceResult=try GaoActionV1.createResultPackage(in:out,request:researchChooseManifest,status:.completed,provenance:["workflowState":"selected","selectionCount":1],references:[fixtureRef])
            for (name,url) in [("research-import.gaoaction",research),("choose-request.gaoaction",chooseURL),("choose-result.gaoaction",fixtureResult),("research-choice-result.gaoaction",researchChoiceResult)] {
                try fm.copyItem(at:url,to:destination.appendingPathComponent(name))
            }
            let validDocs=try GaoActionV1.createRequestPackage(in:out,action:"documents.open",targetBundleID:"com.gaoseries.GaoWenJian",inputFiles:[source])
            try fm.copyItem(at:validDocs,to:destination.appendingPathComponent("documents-open.gaoaction"))
            try Data("parser fixtures generated by GaoZhengLi; originals are disposable".utf8).write(to:destination.appendingPathComponent("README.txt"))
        }
        print("PASS Exchange: \(passed) assertions; isolated original temporary files; no GUI/app launched")
    }
}
