import Foundation

enum MovePlanState: String, Codable, Sendable {
    case draft, validated, awaitingConfirmation, executing, committed, cancelled, failed, needsRecovery
}

enum MoveOperationState: String, Codable, Sendable {
    case pending, validated, renameIntent, moved, rollbackIntent, rolledBack, failed
}

struct MoveSnapshot: Codable, Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
    var flags: UInt32
    var linkCount: UInt64
    var sha256: String
    var metadataSHA256: String

    /// A rename may update ctime. Contents, identity and all captured metadata must remain equal.
    func matchesMovedObject(_ other: MoveSnapshot) -> Bool {
        var lhs = self
        lhs.changedSeconds = other.changedSeconds
        lhs.changedNanoseconds = other.changedNanoseconds
        return lhs == other
    }
}

struct MoveJournalEntry: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    var phase: String
    var detail: String
}

struct MoveOperation: Codable, Sendable, Identifiable {
    var id = UUID()
    var source: URL
    var destination: URL
    var snapshot: MoveSnapshot?
    var targetSnapshot: MoveSnapshot?
    var sourceParentDevice: Int64?
    var sourceParentInode: UInt64?
    var targetParentDevice: Int64?
    var targetParentInode: UInt64?
    var crossVolume: Bool = false
    var state: MoveOperationState = .pending
    var journal: [MoveJournalEntry] = []
    var failure: String?
}

struct MovePlan: Codable, Sendable, Identifiable {
    var id = UUID()
    var revision = 0
    var createdAt = Date()
    var updatedAt = Date()
    var state: MovePlanState = .draft
    var operations: [MoveOperation]
    var sourceRoots: [MoveAuthorization.Root] = []
    var destinationRoot: MoveAuthorization.Root?
    var failure: String?
    var estimatedBytes: Int64 { operations.reduce(0) { $0 + ($1.snapshot?.size ?? 0) } }
}

struct MoveConfirmation: Sendable {
    let planID: UUID
    let revision: Int
    init(planID: UUID, revision: Int) { self.planID = planID; self.revision = revision }
}

/// These roots must originate in current user authorization. This value does not grant sandbox access.
/// The caller must hold security scopes until the synchronous engine operation returns.
struct MoveAuthorization: Sendable {
    struct Root: Codable, Sendable {
        let url: URL
        let device: Int64
        let inode: UInt64
    }
    let sourceRoots: [Root]
    let destinationRoot: Root
    init(sourceRoots: [URL], destinationRoot: URL) throws {
        self.sourceRoots = try sourceRoots.map { try MoveEngine.authorizationRoot($0) }
        self.destinationRoot = try MoveEngine.authorizationRoot(destinationRoot)
        guard !self.sourceRoots.isEmpty else { throw MoveError.denied("没有来源目录授权。") }
    }
}

enum MoveFaultPoint: String, Sendable {
    case beforeJournal, afterJournal, beforeRename, afterRename, beforeCommit, afterCommit
    case beforeRollback, afterRollback
}

/// Tests use this to leave exactly the on-disk state a killed process would leave.
struct MoveInjectedCrash: Error {}

enum MoveError: Error, LocalizedError {
    case denied(String), unsupported(String), conflict(String), changed(String), invalid(String), storage(String), cancelled(String)
    var errorDescription: String? {
        switch self {
        case .denied(let s), .unsupported(let s), .conflict(let s), .changed(let s), .invalid(let s), .storage(let s), .cancelled(let s): return s
        }
    }
}
