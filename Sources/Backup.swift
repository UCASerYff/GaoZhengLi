import Foundation
import CryptoKit

extension AppModel {
    func createBackup() async {
        guard !backingUp, !moving, exchange?.busy != true, let index, let directory else { status = "请等待当前操作结束后再备份。"; return }
        backingUp = true; monitorForBackupStop()
        defer { backingUp = false; configureMonitor() }
        while scanning { try? await Task.sleep(nanoseconds: 100_000_000) }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00"
            let target = AppLocations.backups.appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)", isDirectory: true)
            try await Task.detached(priority: .utility) {
                try BackupEngine.create(index: index, directory: directory, target: target, version: version)
            }.value
            status = "备份已生成并逐文件核对：\(target.lastPathComponent)"
        } catch { status = "备份未通过核验：" + error.localizedDescription }
    }
    func monitorForBackupStop() { stopForBackup() }
}
