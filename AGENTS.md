# 搞整理

- 独立原生 macOS SwiftUI/AppKit 应用，com.gaoseries.GaoZhengLi，首次 V1.00 / build 1。
- 仅修改本目录、本 App 安装与私有资料；不修改兄弟应用或读取其业务数据库。
- 安装 /Applications/搞整理.app；私有资料 ~/Library/Application Support/GaoSeries/GaoZhengLi；长期备份相邻 GaoZhengLi-Backups。
- 默认虚拟整理；原件操作要求授权、身份重验、预览与单独确认。关联管理确认后执行并读回。禁止静默覆盖。
- Sources 是应用源码；Scripts/build.sh 构建；Scripts/test.sh 只跑隔离定向测试，不自启 App/浏览器/GUI。安装不附带 open。
- 版本来源 VERSION、BUILD；正式更新版本十进制 +0.01、build +1。交付前修复保持首次版本。
- 无有效开发证书时本地 ad-hoc 签名，未公证，不能声称 Developer ID 发行。
- 源码、原创图标、说明、许可与最新版发行包留本目录；发行不含用户资料、书签、备份、钥匙串、私密路径或凭据。
- 使用受保护初始化标记、SQLite 迁移、恢复日志；已初始化但缺库、损坏、过新格式时 fail closed。
- 默认不执行冒烟测试，不自动启动应用。真实 GUI、授权、默认关联变更、跨 App 真人接力及硬件体验未实测应明确报告。

## 启动台重复入口保护（2026-10-18）

- 本机确认：项目根目录的展开版 `搞整理.app` 和长期备份的 `Previous.app` 会被 LaunchServices/Spotlight 重新收录；仅执行 lsregister -u 不能持久防重复。
- 正式可启动/可搜索入口只保留 `/Applications/搞整理.app`。项目中的程序保留在 `dist/` 的 DMG/ZIP；构建临时输出安装后须与发行 ZIP 解压结果逐文件核对，再移除展开副本。系统安全属性无法从 ZIP 完整恢复时，旧程序原对象可保存在经完整核验且精确注销登记的私有 `Program.noindex` 备份中。
- 旧程序长期备份保留为 ZIP，必须先解压到隔离临时目录，与原清单逐文件核对并验证签名，才能移除展开的 `Previous.app`；保留原 `backups.app` 清单，并追加 `archivedBackups.app` 的压缩包位置、大小、SHA-256、根目录名与恢复核验依据。用户资料和备份不删除。
- V1.01 起正常 build 仅保留压缩发行包；app-only 只允许私有 `.noindex` 容器内的临时路径。install 支持发行 ZIP，旧程序直接压缩并经恢复核验，实际换装须持共享前台租约。
- 完成后按准确 Bundle ID 查询全部登记，应只返回 `/Applications/搞整理.app`。精准取消本 App 的源码/备份副本登记，不清空全局登记、不重置启动台或 Dock、不改其他应用。

- V1.01/build2 为 2026-10-24 支持搞文件/搞研究 `files.choose` 的窄依赖修复，不代表启动搞整理完整验收任务。普通文件引用使用专用 fractional mtime；全局 formatDate/TTL 及校验容差不得顺带放宽。此轮只运行新定向对照与必要打包安全检查，不重跑未修改模块的广泛旧套件。

- 若且仅若旧程序 ZIP 恢复只缺原根目录 `com.apple.macl`，不得忽略、移除或改写它。安装器保留完整原程序对象到同文件系统的 `Program.noindex/搞整理.app`；移动前同时写安装和恢复收据，移动后核对原 device/inode、全部清单、属性、Info 与签名。ZIP 仅标补充副本；其他差异/跨卷继续拒绝。恢复从收据的 authoritativePath 取完整原对象，不以补充 ZIP 冒充完整恢复。
