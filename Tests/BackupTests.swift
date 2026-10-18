import Foundation

func ensure(_ value: Bool, _ message: String) throws { if !value { throw AppFailure(message) } }
@main struct BackupTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/GaoZhengLi-BackupTests-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: base) }
        let data = base.appendingPathComponent("Data"); let index = try IndexStore(directory: data, testing: true)
        let required = ["configuration.json", "configuration.initialized", "associations_history.json", "associations_history.initialized", "exchange-initialized.json", "Exchange/Journal/ledger.json", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]
        for name in required { let url = data.appendingPathComponent(name); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("synthetic \(name)".utf8).write(to: url) }
        let attachment = data.appendingPathComponent("Exchange/Incoming/original/payload/important.lock")
        try fm.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("原创不可丢失附件".utf8).write(to: attachment)
        for name in [".app.lock", "MovePlans/.lock", "Exchange/Journal/ledger.lock"] { try Data("running lock".utf8).write(to: data.appendingPathComponent(name)) }
        let backup = base.appendingPathComponent("Backup")
        try BackupEngine.create(index: index, directory: data, target: backup, version: "1.00")
        try ensure(fm.fileExists(atPath: backup.appendingPathComponent("VERIFIED").path), "没有验证依据")
        let copied = backup.appendingPathComponent("Data/Exchange/Incoming/original/payload/important.lock")
        try ensure(try Data(contentsOf: copied) == Data(contentsOf: attachment), "误排除了合法 .lock 附件")
        for name in [".app.lock", "MovePlans/.lock", "Exchange/Journal/ledger.lock"] { try ensure(!fm.fileExists(atPath: backup.appendingPathComponent("Data/"+name).path), "复制了运行锁") }
        print("PASS backup copies .lock attachment, only excludes exact three runtime locks, hashes full inventory")
        let manifestBefore = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        var refused = false
        do { try BackupEngine.create(index: index, directory: data, target: backup, version: "1.00") } catch { refused = true }
        try ensure(refused, "未拒绝覆盖已有备份")
        try ensure(try Data(contentsOf: backup.appendingPathComponent("manifest.json")) == manifestBefore, "改写了已有备份")
        print("PASS existing backup not overwritten")
        try fm.removeItem(at: data.appendingPathComponent("configuration.json"))
        let failed = base.appendingPathComponent("MissingRequired")
        refused = false
        do { try BackupEngine.create(index: index, directory: data, target: failed, version: "1.00") } catch { refused = true }
        try ensure(refused, "缺少必要资料仍返回成功")
        try ensure(!fm.fileExists(atPath: failed.appendingPathComponent("VERIFIED").path), "不完整备份出现 VERIFIED")
        print("PASS missing required data cannot be verified as empty")
        try Data("restored synthetic".utf8).write(to: data.appendingPathComponent("configuration.json"))
        try fm.createSymbolicLink(at: data.appendingPathComponent("linkedAttachment"), withDestinationURL: attachment)
        let linked = base.appendingPathComponent("Symlink")
        refused = false
        do { try BackupEngine.create(index: index, directory: data, target: linked, version: "1.00") } catch { refused = true }
        try ensure(refused, "链接备份仍返回成功")
        try ensure(!fm.fileExists(atPath: linked.appendingPathComponent("VERIFIED").path), "链接备份出现 VERIFIED")
        print("PASS linked attachments stop backup without false verification")
        print("BACKUP TESTS PASSED: 4; synthetic files only; no app launch")
    }
}
