# 搞整理

原生 macOS 文件查找与虚拟工作区，V1.00 / build 1。SwiftUI + AppKit，Apple Silicon，macOS 14 或更新版本。

- SQLite 元数据索引，授权根、卷与对象身份核验、FTS5 运行时探测、可取消/续扫与 FSEvents 提示回补。
- 中文与 Unicode 搜索，名称/路径/类型/扩展名/大小/日期/目录筛选，排序分页、收藏、应用内标签和保存查询。
- 虚拟工作区组合目录、查询和收藏面板；折叠、暂停、排序与重排。配置变更不搬动原件。
- 用公开 NSWorkspace 接口读写指定 UTType/URL scheme 默认应用，单独确认、系统读回和历史恢复；单次打开另设入口。
- 同卷普通文件移动/重命名先生成计划，持久日志早于排他改名，中断不重放，核验后恢复不覆盖新资料。
- GaoAction V1 提供 `files.search`、`files.choose`、`files.reveal`、`associations.manage`；消费搞文件/搞研究的明确能力，用户复核和发送。
- 独立设置窗口（⌘,），系统外观、本地资料核验备份、缺失/损坏/过新格式停止写入。

所有源码、原创图标、构建/安装脚本、测试和最新发行包都保存在本项目。用户业务资料独立存储在 `~/Library/Application Support/GaoSeries/GaoZhengLi/`；备份为相邻 `GaoZhengLi-Backups/`，不会进入发行物。

## 构建、测试与安装

```sh
Scripts/test.sh
Scripts/build.sh
python3 Scripts/install.py "$PWD/搞整理.app"
```

构建默认 ad-hoc 签名；本次正式产物使用已验证的 Apple Development 团队 5G96498KGJ 证书，通过环境变量 `GAOZHENGLI_SIGN_IDENTITY` 指定。本机开发签名不等于 Developer ID 公证。`Scripts/build.sh --app-only /absolute/new.app` 可仅生成程序。构建不启动程序；测试使用隔离原创临时文件，不改真实默认关联。

安装脚本只处理本 Bundle，安装前备份并逐文件核验已有资料、设置与旧程序；失败恢复旧程序，保留长期备份。安装不附带 `open`。发行包位于 `dist/`，源代码压缩包由版本控制的公开文件生成，SHA-256 随发行提供。

## 支持边界与验收

本版物理整理只支持同卷独立普通文件。跨卷、目录/应用包、符号链接、多硬链接和离线占位内容拒绝执行，不会用不保真的复制然后删原件。无桌面悬浮面板或 Widget。查询不读正文，索引不主动请求云端内容。

静态编译和隔离定向测试已完成；真实 GUI、系统目录授权/撤销、磁盘拔插/同名卷、睡醒 FSEvents、iCloud/File Provider 不下载、默认关联真人确认与安装版跨应用真人往返尚未验收。没有 Magic Mouse 或第二显示器证据。详见 [交付与验证](Docs/DELIVERY.md)、[索引设计](Docs/INDEX.md)、[移动计划](Docs/MOVE.md)、[跨应用契约](Docs/EXCHANGE.md) 和 `使用说明.txt`。

## 公开 API 依据

- [Apple：设置指定 UTType 默认应用](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:))，本机 macOS SDK 标注 macOS 12+；应用最低版本设为 14。
- [Apple：security-scoped bookmarks 与成对访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。应用私有根书签不会作为跨进程授权传给其他 App。
- [Apple：FSEvents 使用与丢失事件回补](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)。事件仅为提示，元数据扫描才是核对依据。

## 许可

MIT。图标使用程序化原创构图，纯灰 `#777777` 860×860 圆角色块、透明外围、白色竖排系统楷体字形，1024×1024；只包含渲染轮廓，不分发系统字体文件。GaoAction 实现基于本工作区同系列既有公开协议代码的适配，未复制第三方产品实现、私有资产或用户数据。
