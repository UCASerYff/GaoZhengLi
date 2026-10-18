import Foundation
import CryptoKit

private struct BackupEntry: Codable { var path: String; var size: UInt64; var sha256: String }
private struct BackupManifest: Codable { var schemaVersion = 1; var appVersion: String; var generatedAt: Date; var initialized = true; var entries: [BackupEntry] }

enum BackupEngine {
static func create(index: IndexStore, directory: URL, target: URL, version: String) throws {
                let fm = FileManager.default
                guard !fm.fileExists(atPath: target.path) else { throw AppFailure("备份目标已存在，不覆盖任何备份。") }
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let filesRoot = target.appendingPathComponent("Data", isDirectory: true)
                try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try index.backupDatabase(to: filesRoot.appendingPathComponent("metadata.sqlite"))
                var enumerationError: Error?
                guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法读取资料清单。") }
                for case let source as URL in enumerator {
                    let relative = String(source.path.dropFirst(directory.path.count + 1))
                    if ["metadata.sqlite", "metadata.sqlite-wal", "metadata.sqlite-shm"].contains(relative) || [".app.lock", "MovePlans/.lock", "Exchange/Journal/ledger.lock"].contains(relative) { continue }
                    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw AppFailure("资料中存在符号链接，备份已停止。") }
                    let dest = filesRoot.appendingPathComponent(relative)
                    if values.isDirectory == true { try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                    else { try fm.copyItem(at: source, to: dest); guard try fileDigest(source) == fileDigest(dest) else { throw AppFailure("备份读取前后内容变化，已停止。") }; try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path) }
                }
                if let enumerationError { throw enumerationError }
                let required = ["metadata.sqlite", "index-initialized.json", "configuration.json", "configuration.initialized", "associations_history.json", "associations_history.initialized", "exchange-initialized.json", "Exchange/Journal/ledger.json", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]
                for name in required where !fm.fileExists(atPath: filesRoot.appendingPathComponent(name).path) { throw AppFailure("备份缺少必要资料：\(name)") }
                var entries: [BackupEntry] = []
                guard let copied = fm.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法核对备份。") }
                for case let url as URL in copied {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if values.isRegularFile == true { entries.append(BackupEntry(path: String(url.path.dropFirst(filesRoot.path.count+1)), size: UInt64(values.fileSize ?? 0), sha256: try fileDigest(url))) }
                }
                if let enumerationError { throw enumerationError }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                let manifest = BackupManifest(appVersion: version, generatedAt: Date(), entries: entries.sorted { $0.path < $1.path })
                let data = try encoder.encode(manifest)
                try data.write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
                for entry in manifest.entries { guard try fileDigest(filesRoot.appendingPathComponent(entry.path)) == entry.sha256 else { throw AppFailure("备份核对不一致。") } }
                try Data("verified=sha256; schema=1\n".utf8).write(to: target.appendingPathComponent("VERIFIED"), options: .atomic)
}

}

private func fileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
