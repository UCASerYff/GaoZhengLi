# 本地元数据索引

V1.00 使用系统 SQLite。首次打开时创建临时 FTS5 虚拟表进行运行时探测，成功后建立 `unicode61` 元数据全文索引；系统不支持时保留参数化子串查询。索引不读正文，不上传文件名或路径。中文子串、空格、引号和百分号均作为字面文本；查询先做 Unicode NFC、大小写、宽度及变音归一化，不把用户输入直接拼成 SQL 或 FTS 表达式。用户标签属于本应用，重扫不会改写 Finder 标签。

## 授权与对象身份

目录仅来自用户明确选择的系统 NSOpenPanel。`IndexStore.addRoot(url:)` 保存 security-scoped bookmark；`accessLease(rootID:)` 保持访问范围，异步操作应持有该 lease 到任务结束，并调用 `release()`。同步调用使用 `withRootAccess(id:body:)` 成对管理。非沙箱本地签名应用的 scope 返回 false 时，仍要求所选书签成功解析、目录可读且卷、device、inode、创建时间全部匹配，不把 false 当作新的全盘授权。系统保护或 TCC 拒绝会如实失败。

根身份采用卷 UUID（系统未提供时明确降级为 device 身份）、device、inode 和根创建时间；每个文件记录卷、device、inode、创建时间和独立 UUID。相对路径负责定位目录项，不能证明对象身份。硬链接各有目录项 UUID，底层 inode 可相同。唯一旧对象改名后复用 UUID 并保留标签/收藏；同一 inode 的多个硬链接保留各自原路径的标注，新增目录项不会伪造另一条目的 UUID。重新连接后若 device 变化，拒绝直接按旧授权操作；用户重新选择相同卷/根身份后更新授权并要求补扫。

路径遍历从固定根目录 FD 出发，逐层 `openat(O_DIRECTORY | O_NOFOLLOW)`，条目用 `fstatat(AT_SYMLINK_NOFOLLOW)` 读取现成元数据，不跟随链接。每个完成目录单元在接受前再核对仍为同一目录。符号链接仅索引链接本身，打开默认拒绝；Finder 定位可显式允许链接本身。包作为整体、不枚举内部。默认排除隐藏名称、Library、GaoSeries、容器及系统目录；不跨挂载点递归。iCloud/File Provider 的 SF_DATALESS 占位项只记元数据，目录占位项也不进入，不请求下载、缩略图、哈希或正文。用户明确打开时交给系统内容访问流程。

动作通过 `withVerifiedURL(for:allowSymbolicLink:body:)` 即时复核 device/inode/创建时间；原路径替换后拒绝。路径交给外部应用后，本应用无法把外部应用的后续操作绑定到自己的 FD，接收方仍须独立复核。索引本身不提供删除、移动或内容写入操作。

## 数据库与迁移

`metadata.sqlite` 使用 WAL、foreign_keys 与 FULL synchronous。`index-initialized.json` 独立存储数据库随机 ID，与 `index_meta.databaseID` 绑定。主应用另有目录外的初始化记录，检测整个资料目录缺失。已有 DB 缺 marker、marker 缺 DB、ID 不匹配、不可读/损坏、过新版本均停止写入；不自动新建空白资料。打开已有库先 quick_check 并核对版本及初始化身份，随后才进行迁移。初始化中断产生不完整组合也进入恢复。

当前索引 schemaVersion=2：

| 表 | 用途 |
|---|---|
| index_meta、schema_history | 数据库身份和迁移记录 |
| authorized_roots | 根 UUID、书签、卷/目录身份、暂停状态、最后成功扫描与 FSEvents ID |
| files | 完整已发布快照、对象身份、相对路径、类型、大小、时间、包/链接/占位标志、应用标签/收藏 |
| scan_checkpoints | 每根扫描代次、待扫目录栈、已扫描数、起始事件 ID |
| staged_files | 尚未发布的扫描快照；取消或失败不会取代完整 files |
| metadata_fts（可用时） | 规范化名称/路径、UTType、用户标签的 FTS5 元数据 |

`files_identity(root_id,volume,device,inode)` 用于身份匹配；另有名称排序、根/扩展名/时间/大小筛选和 staging 索引。路径有根内唯一约束以表达目录项，不作为对象身份依据。v1→v2 在事务中增加标签/收藏；旧根若缺创建身份，要求重新选择目录授权，保留原元数据。工作区、面板、关联和移动日志由本应用各自受保护文档管理，不混在文件系统事实表。

扫描仅允许一项并行工作。每个目录枚举完成后，同一 SQLite 事务写暂存和检查点；取消/权限错误/路径替换保留上次完整索引。全部目录完成并复核根身份后，事务中发布新快照、删除旧代次和暂存。目录级恢复会继续尚未完成目录；已经完成目录在后续事件提示或手动重扫中补核。并发变化下，普通文件系统枚举不是时点快照，FSEvents 提示和补扫用于最终收敛。检查点里的目录消失等情况可选择 `discardScanCheckpoint(rootID:)`，仅清未完成快照，再从头补扫；原完整索引和应用标注不变。

`IndexMonitor` 每根维持 scope lease，FSEvents 只作提示，1.2 秒合并连续事件，记录 ID 并请求主应用后台补扫。事件丢失、根移动、卸载/重新连接均要求重新核验/完整扫描。暂停根不监听/扫描。扫描期间收到新事件会保留 changed 状态，避免把更新提示当成已处理。首次运行、重新启动、睡醒与长时间离线仍建议完整补扫；FSEvents 不被宣称为完整事实源。

`backupDatabase(to:)` 在数据库锁下使用 SQLite online backup（包含 WAL 的一致事务视图），检查 quick_check，不覆盖已有备份。主应用负责同时保护配置、独立初始化记录、关联/移动/交接日志，并生成完整文件清单和摘要。

## API 使用

所有可能耗时的扫描和搜索由 UI 的 detached worker 调用。数据库短事务使用递归锁，不在主线程枚举目录。搜索有参数化名称/路径/扩展名/UTType（含类型族从属关系）/大小/日期/文件或目录/收藏/标签/目录范围、固定允许的排序，最多 500 项分页。主界面负责输入防抖、取消旧任务及代次核对，防止旧结果覆盖新查询。

```swift
let store = try IndexStore(directory: privateDirectory)
let root = try store.addRoot(url: selectedDirectory)
let report = try store.scan(rootID: root.id, cancel: { flag.isCancelled })
let page = try store.search(SearchFilter(query: "项目"), page: 0, pageSize: 100)
try store.setTags(fileID: file.id, tags: ["项目A"])
try store.setFavorite(fileID: file.id, value: true)
try store.withVerifiedURL(for: file) { verifiedURL in /* user-requested action */ }
```

## 实际定向验证与边界

`Tests/IndexTests.swift` 在原创临时目录编译为独立测试程序，未启动 App/浏览器或任何 GUI。已验证增删改、中文/引号/字面 SQL/Unicode、筛选/排序分页、硬链接与改名身份、包/隐藏目录/链接环边界、目录中途换链接不越界、取消不删完整快照、恢复、标签收藏保留、暂停、online backup 拒绝覆盖、冷重启、迁移、过新版本、缺库及坏初始化。

一次 2000 个合成普通小文件、本机本地临时存储的记录：首扫约 0.23 秒、复扫约 0.66 秒，子串查询 11 项约 0.0024 秒。该结果不代表大库/网络卷/慢盘/云盘性能；首扫前系统缓存未清空，不能称为硬件冷缓存测试。整个定向测试进程（含夹具生成及全部断言）另一次记录 CPU 约 1.066 秒、峰值 RSS 27.69 MiB；不能当作扫描本身的 CPU/内存数值。实际取消延迟未单独测量。真实授权撤销、书签跨重启、卷拔插/同名不同卷、FSEvents 丢事件/睡醒回补、iCloud 占位不下载、真实 GUI 和硬件行为均未用临时测试冒充实测通过。

系统 UTI 声明可用时优先采用其结果；当扩展名只返回 dynamic UTI 或系统类型注册表不可读时，使用公共标准类型的常见扩展名映射及 image/text/audio/movie 家族关系，未知普通文件退化为 public.data。类型完全来自文件名/元数据，不检查或伪称识别实际正文格式。

实现所核对的 Apple 文档：[持久书签与 scope](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))、[FSEvents 及补扫](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)。
