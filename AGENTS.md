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
- 长期只保留 `/Applications/搞整理.app` 这一份展开程序。项目中的程序保留在 `dist/` 的 DMG/ZIP；构建临时输出安装后须与发行 ZIP 解压结果逐文件核对，再移除展开副本。
- 旧程序长期备份保留为 ZIP，必须先解压到隔离临时目录，与原清单逐文件核对并验证签名，才能移除展开的 `Previous.app`；保留原 `backups.app` 清单，并追加 `archivedBackups.app` 的压缩包位置、大小、SHA-256、根目录名与恢复核验依据。用户资料和备份不删除。
- 后续实际应用更新时同步完善 build/install 脚本以遵守以上布局；当前脚本生成的展开产物只能临时使用，不能留作长期发行或备份。
- 完成后按准确 Bundle ID 查询全部登记，应只返回 `/Applications/搞整理.app`。精准取消本 App 的源码/备份副本登记，不清空全局登记、不重置启动台或 Dock、不改其他应用。
