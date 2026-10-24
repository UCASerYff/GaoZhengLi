import AppKit
import CryptoKit
import Darwin
import Foundation

private enum ReferenceMTimeFailure: Error { case assertion(String) }

/// A CLI-only regression test. Consumer probes compile the complete, unchanged
/// consumer source files in separate executables to avoid colliding model names.
@main struct ReferenceMTimeTests {
    private static var passed = 0
    private static let fm = FileManager.default
    private static let seconds = 1_792_737_645
    private static let nanoseconds = [862_398_221, 0, 1, 499_999, 500_000, 999_499_999, 999_500_000, 999_999_999]

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ReferenceMTimeFailure.assertion(message) }
        passed += 1
    }

    private static func rejects(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { passed += 1; return }
        throw ReferenceMTimeFailure.assertion("expected rejection: " + message)
    }

    private static func run(_ executable: URL, _ arguments: [String], in root: URL) throws -> Data {
        let log = root.appendingPathComponent("process-" + UUID().uuidString + ".log")
        guard fm.createFile(atPath: log.path, contents: nil) else {
            throw ReferenceMTimeFailure.assertion("cannot create subprocess log")
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? fm.removeItem(at: log) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        let bytes = try Data(contentsOf: log)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ReferenceMTimeFailure.assertion("subprocess \(executable.lastPathComponent) failed: " + String(decoding: bytes, as: UTF8.self))
        }
        return bytes
    }

    private static func compileProbe(_ name: String, source: String, consumers: [URL], in root: URL) throws -> URL {
        let helper = root.appendingPathComponent(name + ".swift")
        try Data(source.utf8).write(to: helper)
        let executable = root.appendingPathComponent(name)
        let arguments = ["swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox",
                         "-module-cache-path", root.appendingPathComponent("cache").path]
            + consumers.map(\.path) + [helper.path, "-framework", "CryptoKit", "-framework", "Security", "-o", executable.path]
        _ = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments, in: root)
        return executable
    }

    private static func setMTime(_ url: URL, nanoseconds: Int) throws -> stat {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ReferenceMTimeFailure.assertion("cannot open isolated fixture") }
        defer { close(fd) }
        var timestamps = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        guard futimens(fd, &timestamps) == 0 else { throw ReferenceMTimeFailure.assertion("futimens failed: \(errno)") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReferenceMTimeFailure.assertion("fixture fstat failed") }
        try check(info.st_mode & S_IFMT == S_IFREG, "fixture is an ordinary file")
        // Never infer filesystem precision from the requested value.
        try check(info.st_mtimespec.tv_sec == seconds && info.st_mtimespec.tv_nsec == nanoseconds,
                  "filesystem must preserve requested seconds and nanoseconds \(nanoseconds)")
        return info
    }

    private static func assertIdentity(_ reference: GaoActionReference, matches info: stat) throws {
        guard let identity = reference.declaredIdentity else { throw ReferenceMTimeFailure.assertion("missing identity") }
        try check(identity.device == info.st_dev, "device preserved")
        try check(identity.inode == UInt64(info.st_ino), "inode preserved")
        try check(identity.byteCount == UInt64(info.st_size), "size preserved")
    }

    private static func assertEnvelope(_ manifest: GaoActionManifest, now: Date) throws {
        let oldFormatter = ISO8601DateFormatter()
        try check(manifest.createdAt == oldFormatter.string(from: now), "createdAt keeps unchanged whole-second formatter")
        try check(manifest.expiresAt == oldFormatter.string(from: now.addingTimeInterval(120)), "expiresAt keeps unchanged whole-second formatter")
        try check(!manifest.createdAt.contains(".") && !manifest.expiresAt.contains("."), "envelope timestamps remain whole seconds")
        try check(manifest.createdAt.hasSuffix("Z") && manifest.expiresAt.hasSuffix("Z"), "envelope timestamps remain UTC")
        try check(GaoActionV1.parseDate(manifest.expiresAt)!.timeIntervalSince(GaoActionV1.parseDate(manifest.createdAt)!) == 120,
                  "wire TTL remains exactly 120 seconds")
        try check(Data(base64Encoded: manifest.nonce)?.count == 32, "nonce remains 32 bytes")
    }

    static func main() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let workspace = project.deletingLastPathComponent()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("GaoZhengLi-ReferenceMTime-" + UUID().uuidString + ".noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }

        let researchSource = workspace.appendingPathComponent("搞研究/Sources/GaoActionV1.swift")
        let fileSources = ["GaoActionModel.swift", "GaoActionTransport.swift", "FileSafety.swift"]
            .map { workspace.appendingPathComponent("搞文件/Sources/" + $0) }
        let consumerSources = [researchSource] + fileSources
        let sourceBytes = try consumerSources.map { try Data(contentsOf: $0) }
        let researchText = String(decoding: sourceBytes[0], as: UTF8.self)
        let fileTransportText = String(decoding: sourceBytes[2], as: UTF8.self)
        try check(researchText.contains("TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000"),
                  "Research source still uses its original stat-to-Date pipeline")
        try check(researchText.contains("formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]"),
                  "Research source still uses its original fractional formatter")
        try check(fileTransportText.contains("guard abs(actual.timeIntervalSince(expected)) < 0.001 else"),
                  "File source retains the original strict sub-millisecond identity gate")
        for (url, bytes) in zip(consumerSources, sourceBytes) {
            print("consumer-source SHA256 \(GaoActionV1.calculateSHA256(data: bytes)) \(url.path)")
        }

        let researchProbe = try compileProbe("research-reference-probe", source: researchProbeSource, consumers: [researchSource], in: root)
        let fileProbe = try compileProbe("file-reference-probe", source: fileProbeSource, consumers: fileSources, in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let now = Date(timeIntervalSince1970: Double(seconds) + 0.862398221)
        try check(GaoActionV1.requestTTLSeconds == 120, "TTL constant unchanged")
        try check(GaoActionV1.formatDate(now) == ISO8601DateFormatter().string(from: now), "global formatter unchanged")

        let directory = root.appendingPathComponent("directory-fixture", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ReferenceMTimeFailure.assertion("cannot open isolated directory fixture") }
        var directoryTimes = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: nanoseconds[0])]
        let setDirectoryTime = futimens(directoryFD, &directoryTimes)
        var directoryInfo = stat()
        let readDirectoryTime = fstat(directoryFD, &directoryInfo)
        close(directoryFD)
        try check(setDirectoryTime == 0 && readDirectoryTime == 0
                  && directoryInfo.st_mtimespec.tv_sec == seconds && directoryInfo.st_mtimespec.tv_nsec == nanoseconds[0],
                  "directory fixture timestamp readback")
        let directoryReference = try GaoActionV1.reference(for: directory)
        let directoryModified = Date(timeIntervalSince1970: Double(directoryInfo.st_mtimespec.tv_sec) + Double(directoryInfo.st_mtimespec.tv_nsec) / 1_000_000_000)
        try check(directoryReference.kind == .directory
                  && directoryReference.declaredIdentity?.modifiedAt == GaoActionV1.formatDate(directoryModified),
                  "directory reference retains its original whole-second timestamp")

        for nsec in nanoseconds {
            let file = root.appendingPathComponent("fixture-\(nsec).txt")
            try Data("isolated reference timestamp fixture\n".utf8).write(to: file, options: .withoutOverwriting)
            let info = try setMTime(file, nanoseconds: nsec)
            let reference = try GaoActionV1.reference(for: file, id: "mtime-\(nsec)")
            try assertIdentity(reference, matches: info)
            guard let timestamp = reference.declaredIdentity?.modifiedAt,
                  let parsed = GaoActionV1.parseDate(timestamp) else { throw ReferenceMTimeFailure.assertion("missing/invalid modifiedAt") }
            try check(timestamp.hasSuffix("Z") && timestamp.contains("."), "reference modifiedAt is fractional UTC")
            let actual = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            try check(timestamp == GaoActionV1.formatReferenceModifiedAt(actual), "reference(for:) uses only the dedicated formatter")
            try check(abs(actual.timeIntervalSince(parsed)) < 0.001, "exact wire timestamp meets unchanged File strict gate")
            try check(try GaoActionV1.verifyReference(reference) == GaoActionFiles.normalized(file), "producer verifies freshly captured reference")

            let referenceJSON = root.appendingPathComponent("reference-\(nsec).json")
            try encoder.encode(reference).write(to: referenceJSON)
            let requestURL = try GaoActionV1.createRequestPackage(in: root.appendingPathComponent("Outgoing"), action: "documents.open",
                targetBundleID: "com.gaoseries.GaoWenJian", references: [reference], now: now)
            let manifestURL = requestURL.appendingPathComponent("manifest.json")
            let manifest = try GaoActionV1.inspectManifest(at: requestURL, now: now).manifest
            try assertEnvelope(manifest, now: now)
            try check(manifest.references.first?.declaredIdentity?.modifiedAt == timestamp, "request wire keeps fractional reference timestamp")
            let researchOutput = try run(researchProbe, [file.path, referenceJSON.path, manifestURL.path, String(now.timeIntervalSince1970)], in: root)
            guard let values = try JSONSerialization.jsonObject(with: researchOutput) as? [String: Any],
                  let researchTimestamp = values["modifiedAt"] as? String,
                  let researchParsed = values["parsedEpoch"] as? Double else { throw ReferenceMTimeFailure.assertion("Research probe response invalid") }
            try check(researchTimestamp == timestamp, "EXACT wire string equals real Research identity pipeline for \(nsec)")
            try check(researchParsed == parsed.timeIntervalSince1970, "EXACT parsed Date equals real Research parser for \(nsec)")
            _ = try run(fileProbe, [file.path, referenceJSON.path, manifestURL.path, String(now.timeIntervalSince1970)], in: root)
            passed += 1 // actual unchanged File decode + validate + verifyReference succeeded

            var differentSecond = reference
            differentSecond.declaredIdentity!.modifiedAt = GaoActionV1.formatReferenceModifiedAt(actual.addingTimeInterval(1))
            try rejects("different-second modifiedAt \(nsec)") { _ = try GaoActionV1.verifyReference(differentSecond) }
            var wrongInode = reference
            wrongInode.declaredIdentity!.inode = UInt64(info.st_ino) ^ 1
            try rejects("wrong inode \(nsec)") { _ = try GaoActionV1.verifyReference(wrongInode) }
            var wrongDevice = reference
            wrongDevice.declaredIdentity!.device = info.st_dev ^ 1
            try rejects("wrong device \(nsec)") { _ = try GaoActionV1.verifyReference(wrongDevice) }
            var beyondFractionalGate = reference
            beyondFractionalGate.declaredIdentity!.modifiedAt = GaoActionV1.formatReferenceModifiedAt(actual.addingTimeInterval(0.003))
            try rejects("fractional difference beyond unchanged 2ms producer gate \(nsec)") { _ = try GaoActionV1.verifyReference(beyondFractionalGate) }
            print("nsec=\(nsec) readback=\(info.st_mtimespec.tv_sec).\(String(format: "%09d", info.st_mtimespec.tv_nsec)) wire=\(timestamp) deltaMs=\(abs(actual.timeIntervalSince(parsed)) * 1000) Research=exact File=accepted")

            if nsec == nanoseconds[0] {
                let resultURL = try GaoActionV1.createResultPackage(in: root.appendingPathComponent("Outgoing"), request: manifest,
                    status: .completed, provenance: ["workflowState": "opened"], now: now)
                let result = try GaoActionV1.inspectManifest(at: resultURL, now: now).manifest
                try assertEnvelope(result, now: now)
                try check(result.requestID != manifest.requestID && result.nonce != manifest.nonce && result.inReplyTo == manifest.requestID,
                          "result retains new UUID/nonce and inReplyTo")
                var malformed = manifest
                malformed.expiresAt = GaoActionV1.formatReferenceModifiedAt(GaoActionV1.parseDate(manifest.createdAt)!.addingTimeInterval(120.001))
                try rejects("TTL over 120s") { try GaoActionV1.validateManifest(malformed, now: now) }
                malformed = manifest; malformed.nonce = Data(repeating: 0, count: 31).base64EncodedString()
                try rejects("31-byte nonce") { try GaoActionV1.validateManifest(malformed, now: now) }
                try rejects("expiration boundary") { try GaoActionV1.validateManifest(manifest, now: GaoActionV1.parseDate(manifest.expiresAt)!) }
                var seen = Set<String>()
                try GaoActionV1.validateManifest(manifest, now: now, knownIDs: &seen)
                try rejects("duplicate request ID") { try GaoActionV1.validateManifest(manifest, now: now, knownIDs: &seen) }
            }
        }
        for (url, before) in zip(consumerSources, sourceBytes) {
            try check(try Data(contentsOf: url) == before, "consumer source unchanged after real parser probes")
        }
        print("ReferenceMTimeTests passed \(passed) checks; 8 exact Research comparisons and 8 original File parser/identity checks. CLI only; no app, GUI, real user file, or system time was opened/changed.")
    }

    private static let researchProbeSource = #"""
    import Foundation
    @main struct ResearchReferenceProbe {
        static func main() throws {
            let args = CommandLine.arguments
            let url = URL(fileURLWithPath: args[1])
            let reference = try JSONDecoder().decode(GaoActionReference.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let captured = try GaoActionReference.capture(at: url, kind: "file")
            let validator = GaoActionPackageValidator(expectedTargetBundleID: "com.gaoseries.GaoWenJian", now: Date(timeIntervalSince1970: Double(args[4])!))
            _ = try validator.validateManifestData(Data(contentsOf: URL(fileURLWithPath: args[3])))
            guard let actual = captured.declaredIdentity.modifiedAt, actual == reference.declaredIdentity.modifiedAt,
                  let parsed = GaoActionISO8601.date(actual), let received = GaoActionISO8601.date(reference.declaredIdentity.modifiedAt!),
                  parsed == received else { throw GaoActionError.sourceChanged }
            let output: [String: Any] = ["modifiedAt": actual, "parsedEpoch": parsed.timeIntervalSince1970]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
        }
    }
    """#

    private static let fileProbeSource = #"""
    import Foundation
    @main struct FileReferenceProbe {
        static func main() throws {
            let args = CommandLine.arguments
            let reference = try JSONDecoder().decode(GaoActionReference.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let manifest = try GaoActionTransport.decodeManifest(Data(contentsOf: URL(fileURLWithPath: args[3])))
            try GaoActionContract.validate(manifest, expectedTargetBundleID: GaoActionContract.bundleID, now: Date(timeIntervalSince1970: Double(args[4])!))
            guard manifest.references == [reference] else { throw GaoActionContract.reject("fixtureMismatch", "Reference wire differs") }
            try GaoActionTransport.verifyReference(reference, selectedURL: URL(fileURLWithPath: args[1]))
            print("accepted by original File parser and strict <0.001s identity gate")
        }
    }
    """#
}
