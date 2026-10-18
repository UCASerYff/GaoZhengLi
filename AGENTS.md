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
