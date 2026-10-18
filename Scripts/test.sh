#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
TASK_TEST_DIR=$(mktemp -d /private/tmp/gaozhengli-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
COMMON=(-swift-version 5 -Xfrontend -disable-sandbox -module-cache-path "$TASK_TEST_DIR/cache")
xcrun swiftc "${COMMON[@]}" "$PROJECT_DIR"/Sources/Index*.swift "$PROJECT_DIR/Tests/IndexTests.swift" -framework UniformTypeIdentifiers -framework CoreServices -lsqlite3 -o "$TASK_TEST_DIR/index-tests"
"$TASK_TEST_DIR/index-tests"
xcrun swiftc "${COMMON[@]}" "$PROJECT_DIR/Sources/MoveModels.swift" "$PROJECT_DIR/Sources/MoveEngine.swift" "$PROJECT_DIR/Tests/MoveTests.swift" -o "$TASK_TEST_DIR/move-tests"
"$TASK_TEST_DIR/move-tests"
xcrun swiftc "${COMMON[@]}" "$PROJECT_DIR"/Sources/Exchange*.swift "$PROJECT_DIR/Tests/ExchangeTests.swift" -framework AppKit -framework UniformTypeIdentifiers -framework Security -framework CryptoKit -o "$TASK_TEST_DIR/exchange-tests"
"$TASK_TEST_DIR/exchange-tests"
if [[ -f "$PROJECT_DIR/Tests/AssociationTests.swift" ]]; then
 xcrun swiftc "${COMMON[@]}" "$PROJECT_DIR/Sources/Associations.swift" "$PROJECT_DIR/Sources/Configuration.swift" "$PROJECT_DIR/Sources/IndexModels.swift" "$PROJECT_DIR/Tests/AssociationTests.swift" -framework AppKit -framework CryptoKit -o "$TASK_TEST_DIR/association-tests"
 "$TASK_TEST_DIR/association-tests"
fi
xcrun swiftc "${COMMON[@]}" "$PROJECT_DIR"/Sources/Index*.swift "$PROJECT_DIR/Sources/Configuration.swift" "$PROJECT_DIR/Sources/BackupEngine.swift" "$PROJECT_DIR/Tests/BackupTests.swift" -framework CoreServices -framework UniformTypeIdentifiers -framework CryptoKit -lsqlite3 -o "$TASK_TEST_DIR/backup-tests"
"$TASK_TEST_DIR/backup-tests"
print '定向隔离测试完成；没有启动 App、浏览器或 GUI，没有修改系统默认关联。'
