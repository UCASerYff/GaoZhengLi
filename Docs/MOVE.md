# 物理整理 V1.00：已实现范围与恢复规则

本版的破坏性操作范围有意限为**同卷、已下载、本机普通文件的移动／重命名**。每个文件必须仅有一个硬链接。目录、App／文档包、符号链接、多重硬链接及跨卷移动明确拒绝；没有复制后删除的降级路径，没有跨卷“完成”的提示。网络卷未作性能或拔盘实测，系统不能提供排他改名时直接失败。目录和其他类型可继续虚拟整理。

默认冲突策略只有“不覆盖”。调用者可为单个文件向 `create` 传入明确新名称；批次内可能混淆的大小写／Unicode 规范化同名项被拒绝。批次不是整体原子事务；取消保留已完成项，用户可单独确认安全恢复。

## API 与授权

`MoveEngine(directory:)` 使用 App 私有资料下的 `MovePlans/`。`MoveAuthorization(sourceRoots:destinationRoot:)` 只记录调用时目录的 device/inode，不授予访问权。GUI 应由用户选目录或使用本 App 根书签，持有成对 security scopes，并在后台线程同步调用引擎：

```swift
let authorization = try MoveAuthorization(sourceRoots: roots, destinationRoot: destination)
let draft = try engine.create(sources: files, destination: destination,
                              rename: nil, authorization: authorization)
let preview = try engine.validate(draft, authorization: authorization)
// 在 GUI 展示每项来源、目标、限制，再由用户单独确认。
let result = try engine.execute(id: preview.id,
    confirmation: MoveConfirmation(planID: preview.id, revision: preview.revision),
    authorization: authorization)
```

`requestCancel(id:)` 立即设置线程安全标记。执行时各文件之间和来源哈希的每个 MiB 检查取消；原子改名后先完成目标校验和日志，再停止下一项。`cancel`、`allPlans`、`plan` 与 `rollback` 会获取操作锁，不能在引擎工作时从主线程同步调用。首次建立预览／验证也读取内容摘要，耗时取决于文件体积，未承诺瞬时取消预览。

只有 `awaitingConfirmation` 加当前 revision 可以启动。`committed` 的重复执行只返回既有结果；失败、取消或中断计划禁止重放。需要重试时建立新预览。`rollback(id:authorization:)` 必须由用户重新授权并明确选择；没有自动恢复／自动重试原件操作。

## 持久化和状态机

移动日志使用独立 JSON 账本，而非索引 SQLite 的占位表：

- `MovePlans/initialized.json`：schemaVersion=1、storeID。
- 相邻 `MovePlans.initialized`：同一 storeID 的独立初始化依据，检测整个日志目录丢失。
- `MovePlans/ledger.json`：SHA-256 校验 envelope；payload 包含 schemaVersion、storeID、全部计划及逐项日志。
- `MovePlans/.lock`：进程生命周期的独占 `flock`。

目录 0700、文件 0600；受限读取，账本上限 32 MiB、1000 个计划，每个最多 256 项。缺失、损坏、摘要错误、过新版本、初始化依据不一致及不安全权限均停止使用，不重建空账本。账本写入私有排他临时项，`fsync` 后原子发布，再同步目录；运行中业务资料和日志必须纳入备份。

计划状态包括 draft、validated、awaitingConfirmation、executing、committed、cancelled、failed、needsRecovery。项状态包括 pending、validated、renameIntent、moved、rollbackIntent、rolledBack、failed。计划包含授权根证据、来源及目标父目录 device/inode、来源快照、目标读回快照、跨卷标记和阶段日志。所有原件改名／回滚之前，意图日志已落盘。重启时 executing 或 rollbackIntent 只变为 needsRecovery，不触碰任何原件。

## 文件安全

根路径及其内部目录逐级 `openat(O_DIRECTORY|O_NOFOLLOW)`，父目录 FD 从最终校验固定至操作完成；不跟随符号链接。重新核对根与父目录身份。普通文件通过 `openat(O_NOFOLLOW)` 固定 FD，比较路径对象与 FD 的前后 stat，并流式 SHA-256。快照包含 dev/inode、大小、纳秒 mtime/ctime、mode、uid/gid、flags、nlink、内容摘要，以及扩展属性／资源分叉和扩展 ACL 摘要。扩展属性／ACL 不能读取或超出上限时拒绝。

根据 Apple TN3150，每个同步文件操作线程暂时关闭 dataless 文件物化，退出时恢复原策略；`SF_DATALESS` 项拒绝。不能设置该策略也拒绝。这避免为了哈希主动下载占位内容，实际 iCloud／第三方 Provider 交互仍未实测。

同卷执行使用公开 Darwin `renameatx_np(..., RENAME_EXCL)`；不覆盖目标，也不调用原件 `unlink`、复制或删除。改名后读回目标身份、内容与元数据。目标不符合原快照时保留现状及日志，进入人工恢复。回滚重新核对目标确为该操作产生的对象、内容／元数据未变化、原来源位置为空，再用排他改名恢复；用户后来新建、修改或替换的文件不覆盖、不删除。回滚本身中断也能在重启后显式恢复。

同用户的其他程序仍可能在最终 stat 与原子改名系统调用之间竞争替换路径；macOS 没有以预期 inode 为条件的 rename API。固定父 FD、最终重复校验和操作后读回可收窄并检测竞争；不能声称防御恶意同用户程序或整个批次事务隔离。检测不一致后不删除对象、不盲目回滚。

## 定向测试与未验收范围

命令（也可由项目 `Scripts/test.sh` 调用）：

```sh
swiftc -module-cache-path /private/tmp/gaozhengli-move-modulecache Sources/MoveModels.swift Sources/MoveEngine.swift Tests/MoveTests.swift -o /private/tmp/gaozhengli-move-tests
/private/tmp/gaozhengli-move-tests
```

29 项合成临时文件测试通过：同卷内容／mode／扩展属性保留、重复提交、单项恢复，确认后编辑／替换来源，已存在及确认后新建目标，日志前后／改名前后／提交前后的六处进程中断，日志 ENOSPC 注入，最终提交前来源变化，执行前取消与部分批次取消，目标编辑／替换／来源占位时安全拒绝回滚，回滚前后中断，授权越界与根替换，不支持类型，日志缺失／初始化依据丢失／整个目录丢失／损坏／过新，双实例日志锁。测试断言实际原件和后来新资料内容保留。

跨卷复制／校验／来源删除没有实现，也不把相关故障注入写成通过；目录清单、跨卷元数据保真、真实磁盘满／拔盘、权限界面、Finder／File Provider 并发、实机 GUI 和真人确认流程未验收。默认未运行冒烟测试，未启动应用。

一手依据：[Apple TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)、本机 macOS SDK `sys/stdio.h` 的 `renameatx_np`（macOS 10.12 起）及 `RENAME_EXCL`、`sys/stat.h` 的 `SF_DATALESS`、系统 `rename(2)`／`acl(3)`／`getxattr(2)` 手册。未用私有 API。
