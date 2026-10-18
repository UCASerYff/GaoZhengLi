# 启动台重复入口处理记录

2026-10-18，V1.00 / build 1；只处理安装副本布局和系统登记，没有更改应用二进制或用户业务资料。

系统实际将三份同 Bundle ID 程序收录为可启动应用：`/Applications/搞整理.app`、项目内的展开版、长期备份中的 `Previous.app`。Spotlight 同时返回正式安装和项目副本，因此搜索出现重复。此前单独取消登记后，仍存在的 `.app` 被重新收录。

本次处理：

1. 确认没有从待归档副本运行的进程；核对所有程序 Bundle ID、版本和签名。
2. 将项目内展开版与现有 `dist/GaoZhengLi-1.00-macOS.zip` 解压结果、正式安装版逐文件核对一致，保留 ZIP/DMG 后移除项目展开副本。
3. 将旧程序备份压缩为私有 `Previous.app.zip`，解压核对原 `backups.app` 清单及签名后，才移除展开副本；原备份清单保留，追加归档摘要与恢复核验记录。
4. 只取消这两个精确路径的应用登记，注册正式安装版。未重置任何全局数据库，未重启 Dock，未启动 App 或运行冒烟测试。

处理后，`NSWorkspace.urlsForApplications(withBundleIdentifier:)` 与 Spotlight 对本 Bundle ID 的查询均只返回 `/Applications/搞整理.app`。没有通过截图或自动打开启动台冒充视觉验收。

源码、当前 DMG/程序 ZIP/源码 ZIP、安全备份及用户资料均保留。今后发布必须按 AGENTS.md 将非安装副本长期保留为已核验的压缩包；不能依赖取消登记或 `.noindex` 阻止展开 App 重新被发现。
