# GaoAction V1（搞整理 V1.00）

## 实现与原始依据

本 App 使用 `com.gaoseries.GaoZhengLi`、文档包 `.gaoaction`、UTType `com.gaoseries.action-package`。只把文档包路径交给系统，不使用带文件名、正文、回调或命令参数的 URL，不提供 HTTP 控制接口。

协议的固定 FD、无链接读取、固定摘要复制、原子不覆盖发布和总留存预算代码来自本工作区搞操作现有 GaoAction V1，再针对本 App 身份与实际接收端适配。已阅读搞操作 `GaoActionV1.swift`、`GaoActionExchange.swift`、`Docs/GaoActionV1.md`，以及搞文件、搞研究的实际模型、读写器、能力解析器和安装版能力表。未修改兄弟 App 源码、数据库或安装包。

文件分工：

- `ExchangeProtocol.swift`：V1 模型、输入白名单、独立原件身份检查、固定 FD 包验证、复制和发包。
- `ExchangeCapabilities.swift`：实际应用标识/版本、参数 schema、输入模式、引用 schema 和预算核对。
- `ExchangeStorage.swift`：本地资料无链接读写、身份/摘要变化检测、原子写入与意外替换保留。
- `ExchangeJournal.swift`：持久去重、校验账本、独立初始化标记、进程文件锁及中断恢复。
- `ExchangeService.swift`：SwiftUI 可观察状态、用户核对、业务上下文、所选结果及显式发送。

## 真正实现的提供方动作

| 动作 | 输入 | 接受后的业务 | 结果 |
| --- | --- | --- | --- |
| `files.search` | 必填 `query`，零或一个 directory reference | 带查询及可选范围的搜索界面 | 只有用户“发送所选”生成有限的普通原件 references；还需“发送结果”递交 |
| `files.choose` | 可选 `allowedUTIs`、`multiple`，零或一个 directory reference | 系统文件选择器，执行范围、数量及类型核对 | 用户所选普通原件 references；取消为空 cancelled |
| `files.reveal` | 一个 file/directory/application reference | 用户同意后，重新核对原件身份并定位 | 实际定位请求后为 completed/revealed；不制造附件 |
| `associations.manage` | 可选有效 `uti` | 打开相应关联界面，继续本 App 独立预览/确认流程 | 只有公开系统接口修改且读回吻合才 completed/changed/readBackVerified；仅打开界面不算完成 |

能力表只声明 `selectionModes/resultModes=["references"]`，不声称选择结果副本模式、跨进程书签或后台自动导入。所选目录、App 包、符号链接和硬链接不伪装成普通文件发送。选择发生变化、身份不清或无权限就停止，由用户重新选择；对接收方仍不保证有权访问。范围 reference 只是描述，不能扩大本 App 已获授权范围。

## 消费方动作与实际兼容适配

- 搞文件：`com.gaoseries.GaoWenJian` / 安装版 1.08，`documents.open`，发送用户选择的文档副本。已核对其数组形式 actions 及 `parametersSchema`。
- 搞研究：`com.academic-achievement.manager` / 安装版 4.05，`research.importDocuments`，发送用户选择的文档副本。其实际能力表为动作名键控对象，schema 字段名为 `parameters`，输入模式为 `fileCopies`；本 App 明确适配此形式并核对实际 schema、应用版本与预算。其实际读取器要求 `relativePath` 从包根的 `payload/` 开始，发往该动作时使用此拼写。搞文件兼容两种载荷路径拼写；本 App 接收验证兼容 payload 相对和包根 payload 前缀，归一后重复路径拒绝。

所有消费者入口都由用户点击触发。发包前、异步复制后和最终递交前核对当前目标能力；能力缺失、标识/版本不符、未支持参数或预算不符会明确停止。`NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)` 显式使用已核对目标，`allowsRunningApplicationSubstitution=false`；系统接受文档打开请求只算递交，不算对方业务完成。

## 接收、安全、状态与恢复

每个包必须具有 schema 1、固定动作、合法 UUID、对应 bundle ID、UTC Z 时间及最长 120 秒有效期、系统随机 32 字节规范 Base64 nonce。结果使用新 UUID、新 nonce、新有效期及 `inReplyTo`。拒绝重复 JSON 键、未知字段/参数、越界路径、任一级父路径符号链接、payload 链接/硬链接、非普通载荷、错误大小/摘要和复制期间变化。

单包 manifest ≤ 1 MiB，items + references ≤ 256，文件载荷 ≤ 2 GiB。入件与发件共用最高 8 GiB、128 个保留包、65536 个遍历项的预算及文件锁。达到上限就停止并提示核对；不按年龄删除尚未完成的包，不清理发送方、用户原件或备份。

接收流程先只读取并验证 manifest 和账本，再复制到本 App 的 `Exchange/Incoming`，保存校验结果并展示动作、来源声明、状态和输入。用户接受后再次核验保留字节及引用身份，才进入业务。来源 bundle ID 和 nonce 都不是认证或授权。

`dataDirectory/exchange-initialized.json` 与 `Exchange/Journal/ledger.json` 分离。账本含版本、递增代次、记录与 SHA-256 校验封装；整个进程用独占锁防止多实例同时写入。已初始化但账本丢失、损坏、过新、校验失配或运行期间被替换时停止写入，不创建空账本。若整个 App 私有资料目录消失，由主资料库的独立初始化/恢复保护继续阻止空白重建。

同 UUID 同字节只显示旧状态；同 UUID 不同字节、跨请求重复 nonce 拒绝。结果还必须匹配本 App 的未完成原请求、动作和源/目标双方。pending 保持 pending，partial 保持 partial；已有终态不被新结果自动替换。

状态为 prepared → dispatched，或 received → approved → executing → completed；执行或确认期间中断，重启转 interrupted，不自动重放业务。业务结果状态与递交状态分开。未接受入件可从交接记录重新核对；已准备未发送的结果可从记录恢复发送。结果在用户等待期间过期时，显式发送会重验原包和原件、用新 UUID/nonce/有效期重封装；并不重复选择、定位或关联修改。更新有效期时在同一次原子账本写入中将旧信封标为 superseded，并登记新信封；新旧业务语义必须完全一致，旧信封不得再次发送。递交失败保留包和 interrupted 记录，人工重发前提示核对目标 App。

## 已执行验证（2026-10-18）

未启动主程序、兄弟 App、浏览器或测试窗口；未操作本机真实默认关联。仅用原创临时文件执行静态编译、隔离测试及解析器互换。

```sh
xcrun swiftc -swift-version 5 -module-cache-path /private/tmp/GaoZhengLi-exchange-module-cache -typecheck Sources/Exchange*.swift
xcrun swiftc -swift-version 5 -module-cache-path /private/tmp/GaoZhengLi-exchange-module-cache Sources/Exchange*.swift Tests/ExchangeTests.swift -o /private/tmp/GaoZhengLi-exchange-tests
/private/tmp/GaoZhengLi-exchange-tests
```

结果：`PASS Exchange: 60 assertions; isolated original temporary files; no GUI/app launched`。

覆盖合法选择/结果、新 UUID+nonce、取消不带所选、中文/引号/组合 Unicode、精确副本摘要、坏 nonce、TTL、过期、过新 schema、未知动作、未声明参数、重复及转义重复 JSON 键、路径越界、父级/载荷符号链接、硬链接、保留副本确认前被改、留存预算、研究实际路径格式、同 UUID 异内容、nonce 重用、执行中断恢复、结果请求/提供方匹配、pending→partial、终态保护、已初始化账本缺失/损坏/校验失配/过新、实际安装能力表两种形式、能力参数/载荷/版本/缺失、用户复核及所选前不生成结果、更新有效期时旧回执原子退役/不可再发送/不得改变业务语义等。

测试支持 `--fixtures /private/tmp/某个全新目录`，额外生成两类消费者请求、两类选择结果与原创所选文件，可供独立解析器验证；不将运行时路径或测试生成包加入发行。

另外实际编译了**未改动**的兄弟源文件，在非 GUI CLI 中验证以下包；搞文件仅补充与其原 `FileSafety.digest` 等价的 SHA-256 测试适配器，没有更改其模型/读取器。

```text
PASS unmodified GaoWenJian parser: documents.open, 1 items / 0 references
PASS unmodified GaoWenJian parser: files.choose, 0 items / 1 references
PASS unmodified GaoYanJiu parser: research.importDocuments, 1 items / 0 references
PASS unmodified GaoYanJiu parser: files.choose, 0 items / 1 references
PASS unmodified GaoWenJian writer: files.choose request
PASS unmodified GaoYanJiu writer: files.choose request
PASS GaoZhengLi parser accepted actual sibling writer: com.gaoseries.GaoWenJian files.choose
PASS GaoZhengLi parser accepted actual sibling writer: com.academic-achievement.manager files.choose
```

被编译的实际兄弟源文件 SHA-256：

```text
195bd6241044e304ffee0bacc8590d1e0a6745cf775d2cc84d40dcfc28120fc8  搞文件/Sources/GaoActionModel.swift
7f8302bb2ac33db4b413e474d249a4a787910538323223e076410b13143fd437  搞文件/Sources/GaoActionTransport.swift
d7f5522aa2e15de7e5718f40c98c1808afc164d750b83b09208b871224cddefc  搞研究/Sources/GaoActionV1.swift
```

这些证明实际读写器对相应生成包的兼容性，并不等同于已安装双方的真人业务验收。以下仍需用户真实交互：系统文件面板授权与撤销、目标 App 接受/导入所选文件、回传结果后消费者原件复核、真实 LaunchServices 接力、默认关联修改与系统读回。未实测跨进程书签，当前不导出书签；默认关联、设备及多屏体验没有通过隔离测试冒充验收。
