#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
TASK_MTIME_ROOT=$(mktemp -d /private/tmp/gaozhengli-mtime.XXXXXX)
trap 'rm -rf "$TASK_MTIME_ROOT"' EXIT
TASK_MTIME_DIR="$TASK_MTIME_ROOT/test.noindex"
mkdir -m 700 "$TASK_MTIME_DIR"
xcrun swiftc -swift-version 5 -Xfrontend -disable-sandbox -module-cache-path "$TASK_MTIME_DIR/cache" \
 "$PROJECT_DIR"/Sources/Exchange*.swift "$PROJECT_DIR/Tests/ReferenceMTimeTests.swift" \
 -framework AppKit -framework UniformTypeIdentifiers -framework Security -framework CryptoKit \
 -o "$TASK_MTIME_DIR/reference-mtime-tests"
"$TASK_MTIME_DIR/reference-mtime-tests"
