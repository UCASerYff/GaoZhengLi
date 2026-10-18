import Foundation
import CryptoKit
import Darwin

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A missing business document is never interpreted as an empty initialized document.
final class ProtectedDocument<Value: Codable> {
    struct Envelope: Codable { let schemaVersion: Int; let sha256: String; let payload: Data }
    let url: URL
    private let marker: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastDiskDigest: String?
    private var creating = false
    init(directory: URL, name: String) {
        url = directory.appendingPathComponent(name + ".json")
        marker = directory.appendingPathComponent(name + ".initialized")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    func load(initial: @autoclosure () -> Value) throws -> Value {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard !fm.fileExists(atPath: marker.path) else { throw AppFailure("资料文件缺失：\(url.lastPathComponent)。请从核验备份恢复，未建立空白资料。") }
            let value = initial(); creating = true; defer { creating = false }; try save(value); try Data("schema=1\n".utf8).write(to: marker, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            return value
        }
        guard fm.fileExists(atPath: marker.path) else { throw AppFailure("资料初始化依据缺失：\(url.lastPathComponent)。停止写入，需恢复核验。") }
        try Self.validateFile(marker)
        guard try Data(contentsOf: marker) == Data("schema=1\n".utf8) else { throw AppFailure("资料初始化依据损坏，停止写入。") }
        try Self.validateFile(url)
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1024 * 1024 else { throw AppFailure("资料过大，停止读取。") }
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw AppFailure("资料格式过新或不支持，停止写入。") }
        guard Self.digest(envelope.payload) == envelope.sha256 else { throw AppFailure("资料摘要不符，停止写入。") }
        let value = try decoder.decode(Value.self, from: envelope.payload)
        lastDiskDigest = Self.digest(data)
        return value
    }
    func save(_ value: Value) throws {
        if !creating {
            try Self.validateFile(marker)
            guard try Data(contentsOf: marker) == Data("schema=1\n".utf8) else { throw AppFailure("资料初始化依据损坏，停止写入。") }
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            try Self.validateFile(url)
            guard let lastDiskDigest, Self.digest(try Data(contentsOf: url)) == lastDiskDigest else { throw AppFailure("资料在读取后被替换或修改，停止写入。") }
        } else {
            guard creating, lastDiskDigest == nil, !FileManager.default.fileExists(atPath: marker.path) else { throw AppFailure("已初始化资料在运行期间缺失，停止写入。") }
        }
        let data = try encoder.encode(value)
        let encoded = try encoder.encode(Envelope(schemaVersion: 1, sha256: Self.digest(data), payload: data))
        try encoded.write(to: url, options: .atomic)
        lastDiskDigest = Self.digest(encoded)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func validateFile(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= 32 * 1024 * 1024 else { throw AppFailure("资料对象类型、身份或大小异常，停止读取与写入。") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct LibraryConfiguration: Codable {
    var schemaVersion = 1
    var workspaces: [VirtualWorkspace] = []
    var savedQueries: [SavedQuery] = []
    var appearance = "system"
    var automaticMonitoring = true
}
struct VirtualWorkspace: Codable, Identifiable {
    var id = UUID()
    var name: String
    var panels: [VirtualPanel] = []
}
struct VirtualPanel: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: String // directory, query, favorites
    var rootID: UUID?
    var query = ""
    var extensionName = ""
    var sort = "name"
    var ascending = true
    var collapsed = false
    var paused = false
    var filter: SearchFilter? = nil
}
struct SavedQuery: Codable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var rootID: UUID?
    var extensionName: String
    var pathContains: String
    var typeIdentifier: String
    var kind: String
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var sort: String
    var ascending: Bool
    var filter: SearchFilter? = nil
}

enum AppLocations {
    private static var lockFD: Int32 = -1
    static let bundleID = "com.gaoseries.GaoZhengLi"
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoZhengLi", isDirectory: true)
    static let backups = directory.deletingLastPathComponent().appendingPathComponent("GaoZhengLi-Backups", isDirectory: true)
    static func prepare() throws -> URL {
        let key = "GaoZhengLi.initialized.v1"
        let fm = FileManager.default
        if UserDefaults.standard.bool(forKey: key) && !fm.fileExists(atPath: directory.path) {
            throw AppFailure("已初始化的资料目录缺失。请恢复资料目录，禁止以空白资料覆盖。")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR else { throw AppFailure("资料目录身份或类型异常。") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if UserDefaults.standard.bool(forKey: key) {
            let expected = ["configuration.json", "configuration.initialized", "metadata.sqlite", "index-initialized.json", "associations_history.json", "associations_history.initialized", "exchange-initialized.json", "Exchange/Journal/ledger.json", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]
            for name in expected where !fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
                throw AppFailure("已初始化资料缺失：\(name)。停止写入，请从完整备份恢复。")
            }
        }
        let fd = open(directory.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppFailure("无法建立资料独占锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AppFailure("另一个搞整理进程正在使用资料，请先退出该进程。") }
        lockFD = fd
        return directory
    }
    static func markInitialized() { UserDefaults.standard.set(true, forKey: "GaoZhengLi.initialized.v1") }
}
