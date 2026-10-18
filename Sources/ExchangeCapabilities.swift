import AppKit
import Foundation
import Darwin
import SwiftUI
import CoreFoundation

struct GaoActionProviderCapabilities: Decodable {
    struct Action: Decodable {
        var action:String
        var parametersSchema:[String:GaoActionAnyCodable]
        var supportsReferences:Bool?
        var supportsItems:Bool?
        var referencesSchema:[String:GaoActionAnyCodable]?
        var requiresUserConfirmation:Bool?
        var reviewOnly:Bool?
        var inputModes:[String]?
        var maximumItems:Int?
        var maximumPayloadBytes:UInt64?
        var requestTTLSeconds:Double?
    }
    var schemaVersion:Int
    var bundleID:String
    var appVersion:String
    var actions:[Action]
    static func load(appURL:URL,bundleID:String) throws -> Self {
        guard let bundle=Bundle(url:appURL),bundle.bundleIdentifier==bundleID,
              let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else {throw GaoActionError.providerNotReady("安装应用的标识或版本无效")}
        let url=appURL.appendingPathComponent("Contents/Resources/GaoCapabilities.json")
        let fd=try GaoActionFiles.openRegular(url,owned:false);defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:GaoActionV1.maximumManifestBytes,owned:false)
        guard var raw=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw GaoActionError.providerNotReady("能力表不是对象")}
        // The installed research provider uses a dictionary of actions with `parameters`.
        // Normalize only its documented spelling; validation below still checks all actual constraints.
        if let actions=raw["actions"] as? [String:[String:Any]] {
            raw["actions"]=actions.map {key,value -> [String:Any] in
                var result=value;result["action"]=key
                result["parametersSchema"]=value["parameters"]
                result.removeValue(forKey:"parameters");return result
            }
        }
        let capabilities=try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:raw))
        guard capabilities.schemaVersion==1,capabilities.bundleID==bundleID,capabilities.appVersion==version,
              capabilities.actions.count<=GaoActionV1.knownActions.count,
              Set(capabilities.actions.map(\.action)).count==capabilities.actions.count else {throw GaoActionError.providerNotReady("能力表 schema、应用标识或版本不匹配")}
        for a in capabilities.actions {
            guard GaoActionV1.knownActions.contains(a.action),GaoActionV1.owners[a.action]==nil || GaoActionV1.owners[a.action]==bundleID,
                  a.parametersSchema["type"]?.value as? String == "object",
                  a.parametersSchema["additionalProperties"]?.value as? Bool == false,
                  let props=a.parametersSchema["properties"]?.value as? [String:Any],
                  Set(props.keys).isSubset(of:GaoActionV1.parameterKeys[a.action] ?? []) else {throw GaoActionError.providerNotReady("提供方声明了不兼容动作或参数 schema")}
        }
        return capabilities
    }
    func require(action:String,parameters:[String:Any],items:Bool,references:Bool) throws {
        guard let capability=actions.first(where:{$0.action==action}) else {throw GaoActionError.providerNotReady("目标应用尚未声明实现 \(action)")}
        guard (!items || capability.supportsItems != false),(!references || capability.supportsReferences != false),
              (!items || capability.inputModes == nil || capability.inputModes!.contains("fileCopies")),
              (!references || capability.inputModes == nil || capability.inputModes!.contains("references")),
              let properties=capability.parametersSchema["properties"]?.value as? [String:Any],Set(parameters.keys).isSubset(of:Set(properties.keys)) else {throw GaoActionError.providerNotReady("提供方未声明本次附件、引用或可选参数")}
        if let required=capability.parametersSchema["required"]?.value as? [String] {
            guard Set(required).isSubset(of:Set(parameters.keys)) else {throw GaoActionError.providerNotReady("提供方额外要求未提供参数")}
        }
        for (key,value) in parameters {
            guard let schema=properties[key] as? [String:Any] else {throw GaoActionError.providerNotReady("提供方参数 schema 无效")}
            try GaoActionParameterSchema.validate(value,schema:schema)
        }
    }
    func requireManifest(_ m:GaoActionManifest) throws {
        try requireInputs(action:m.action,parameters:m.parameters.mapValues(\.value),items:!m.items.isEmpty,references:m.references)
        guard let a=actions.first(where:{$0.action==m.action}),
              a.maximumItems == nil || m.items.count+m.references.count <= a.maximumItems!,
              a.maximumPayloadBytes == nil || m.items.reduce(UInt64(0),{$0+$1.byteCount}) <= a.maximumPayloadBytes!,
              a.requestTTLSeconds == nil || (GaoActionV1.parseDate(m.expiresAt)!.timeIntervalSince(GaoActionV1.parseDate(m.createdAt)!)) <= a.requestTTLSeconds!
        else {throw GaoActionError.providerNotReady("交接包超过提供方声明预算")}
    }
    func requireInputs(action:String,parameters:[String:Any],items:Bool,references:[GaoActionReference]) throws {
        try require(action:action,parameters:parameters,items:items,references:!references.isEmpty)
        guard let capability=actions.first(where:{$0.action==action}),let schema=capability.referencesSchema else {return}
        let values=try references.map { reference -> [String:Any] in
            guard let value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reference)) as? [String:Any] else {
                throw GaoActionError.providerNotReady("无法核验提供方引用约束")
            }
            return value
        }
        try GaoActionParameterSchema.validate(values,schema:schema.mapValues(\.value))
    }
}

private enum GaoActionParameterSchema {
    static func validate(_ value:Any,schema:[String:Any],depth:Int=0) throws {
        func invalid() -> GaoActionError {.providerNotReady("本次参数不符合提供方能力 schema")}
        guard depth<=8 else {throw invalid()}
        if let constant=schema["const"],GaoActionAnyCodable(value) != GaoActionAnyCodable(constant) {throw invalid()}
        // V1 supports this explicit subset, rather than silently ignoring a
        // provider's new validation vocabulary and dispatching incompatible data.
        let supported:Set<String>=["type","const","enum","minimum","maximum","minLength","maxLength","pattern","minItems","maxItems","items","properties","required","additionalProperties","description","title","default"]
        guard Set(schema.keys).isSubset(of:supported) else {throw GaoActionError.providerNotReady("提供方使用了尚未支持的能力约束")}
        guard let type=schema["type"] as? String else {
            guard schema["const"] != nil,Set(schema.keys).isSubset(of:["const","description","title"]) else {throw GaoActionError.providerNotReady("提供方参数 schema 缺少类型")}
            return
        }
        switch type {
        case "string":
            guard let s=value as? String else {throw invalid()}
            if let max=schema["maxLength"] as? Int,s.count>max {throw invalid()}
            if let min=schema["minLength"] as? Int,s.count<min {throw invalid()}
            if let values=schema["enum"] as? [String],!values.contains(s) {throw invalid()}
            if let pattern=schema["pattern"] as? String {guard pattern.utf8.count<=1024,s.range(of:pattern,options:.regularExpression) != nil else {throw invalid()}}
        case "number","integer":
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,type != "integer" || floor(n.doubleValue)==n.doubleValue else {throw invalid()}
            if let max=schema["maximum"] as? Double,n.doubleValue>max {throw invalid()}
            if let min=schema["minimum"] as? Double,n.doubleValue<min {throw invalid()}
        case "boolean":guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw invalid()}
        case "array":
            guard let a=value as? [Any] else {throw invalid()}
            if let max=schema["maxItems"] as? Int,a.count>max {throw invalid()}
            if let min=schema["minItems"] as? Int,a.count<min {throw invalid()}
            if let boolean=schema["items"] as? Bool {
                guard boolean || a.isEmpty else {throw invalid()};return
            }
            guard let item=schema["items"] as? [String:Any] else {throw invalid()}
            for value in a {try validate(value,schema:item,depth:depth+1)}
        case "object":
            guard let object=value as? [String:Any],let properties=schema["properties"] as? [String:Any] else {throw invalid()}
            if let required=schema["required"] as? [String],!Set(required).isSubset(of:Set(object.keys)) {throw invalid()}
            if schema["additionalProperties"] as? Bool == false,!Set(object.keys).isSubset(of:Set(properties.keys)) {throw invalid()}
            for (key,value) in object where properties[key] != nil {
                guard let child=properties[key] as? [String:Any] else {throw invalid()}
                try validate(value,schema:child,depth:depth+1)
            }
        default:throw GaoActionError.providerNotReady("提供方使用了不支持的参数 schema 类型")
        }
    }
}

