# 原件引用修改时间回归验证

`GaoActionV1.reference(for:)` 对普通文件使用专用 UTC ISO8601 小数秒格式器。输入保持 `stat.st_mtimespec.tv_sec + tv_nsec / 1_000_000_000 → Date`，与搞研究现有实现一致。小数秒序列化的舍入由 Foundation 完成，不手动截断到毫秒。目录及应用引用、全局 `formatDate`、请求与结果的 `createdAt`/`expiresAt` 保持原有整秒格式。TTL 仍为 120 秒，原件校验容差及身份字段不变。

## 独立定向测试

在搞整理项目目录执行，命令仅编译并运行命令行单元测试：

```sh
set -e
TASK_MTIME_DIR=$(mktemp -d /private/tmp/gaozhengli-mtime.XXXXXX.noindex)
trap 'rm -rf "$TASK_MTIME_DIR"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -Xfrontend -disable-sandbox \
  -module-cache-path "$TASK_MTIME_DIR/cache" \
  Sources/Exchange*.swift Tests/ReferenceMTimeTests.swift \
  -framework AppKit -framework UniformTypeIdentifiers \
  -framework Security -framework CryptoKit \
  -o "$TASK_MTIME_DIR/reference-mtime-tests"
"$TASK_MTIME_DIR/reference-mtime-tests"
```

测试仅在 `/private/tmp` 的随机 `.noindex` 目录创建普通文件、目录、交接包和临时 CLI，退出后移除；不启动应用、浏览器、模拟器或测试窗口，不读取业务数据库，不修改真实用户文件或系统时间。它不调用原有广泛测试套件。

测试直接编译以下完整、未修改的消费者源码为两个独立 CLI，避免同名模型冲突：

- 搞研究：`Sources/GaoActionV1.swift`，调用真实 `GaoActionReference.capture(at:kind:)` 进入 `GaoSecureFD.identity`，调用真实 `GaoActionISO8601.date` 和 `GaoActionPackageValidator.validateManifestData`。
- 搞文件：`Sources/GaoActionModel.swift`、`Sources/GaoActionTransport.swift`、`Sources/FileSafety.swift`，调用真实 `decodeManifest`、`GaoActionContract.validate` 和 `verifyReference`，执行原有严格 `< 0.001` 秒校验。

这不是复制解析逻辑的替身测试。测试输出完整源文件 SHA-256，并在结束时逐字节核对消费者源码未变。它验证消费者源码级互操作性；已安装应用接收新鲜请求的交互验收由单独步骤记录，不由本测试代替。

每个普通文件用 `futimens` 设置 `tv_sec=1792737645` 和下表纳秒值，再用 `fstat` 确认实际保存的秒及纳秒。测试调用真实生产方 `reference(for:)`，要求 wire 字符串及解析后的 `Date` 与真实搞研究管线完全相同，并由真实搞文件解析及严格身份校验接受。

## 2026-10-24 验证记录

通过 206 项检查，包括 8 个真实搞研究精确对照、8 个真实搞文件原件校验。另验证目录引用保留整秒、不同秒/错误 inode/错误 device/超出生产方原有 2ms 小数秒容差均拒绝，请求及结果时间格式、120 秒 TTL、32 字节 nonce、结果 UUID/nonce/`inReplyTo`、过期和重复请求拒绝规则保持有效。

| `tv_nsec` 实际读回值 | wire `modifiedAt` | 与原始 `Date` 差值（毫秒） |
| --- | --- | ---: |
| 862398221 | `2026-10-23T06:40:45.862Z` | 0.3981590271 |
| 0 | `2026-10-23T06:40:45.000Z` | 0 |
| 1 | `2026-10-23T06:40:45.000Z` | 0 |
| 499999 | `2026-10-23T06:40:45.001Z` | 0.4999637604 |
| 500000 | `2026-10-23T06:40:45.001Z` | 0.4999637604 |
| 999499999 | `2026-10-23T06:40:46.000Z` | 0.4999637604 |
| 999500000 | `2026-10-23T06:40:46.000Z` | 0.4999637604 |
| 999999999 | `2026-10-23T06:40:46.000Z` | 0 |

纳秒端点转换后的 `Date` 受浮点表示及 Foundation 格式化影响，表中毫秒结果不能替换为自行截断规则；测试不假定格式器对中点的手工舍入方式。

本次编译的消费者源码摘要：

| 消费者源码 | SHA-256 |
| --- | --- |
| 搞研究 `GaoActionV1.swift` | `367ce0d59ed6c7427f7ffbdaedcab774cf2c6b3d81bd35f073cf637ce946b713` |
| 搞文件 `GaoActionModel.swift` | `195bd6241044e304ffee0bacc8590d1e0a6745cf775d2cc84d40dcfc28120fc8` |
| 搞文件 `GaoActionTransport.swift` | `d97fcae915adeb2563d81d6cb2b808f4ad064b983199ff959fed25a7e0161f69` |
| 搞文件 `FileSafety.swift` | `389dedf24db397b9ce13584d729e28953ada2469c4943664722e9eec907ed4b9` |

未运行冒烟测试或 GUI 验收。编译器输出了 `sandbox-exec: sandbox_apply: Operation not permitted` 环境诊断，但定向编译、两个真实消费者 CLI 及全部检查均以状态 0 完成。
