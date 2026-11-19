#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
TEST_DIR=$(mktemp -d /tmp/StashCat-mail-tests.XXXXXX)
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/MailStore.swift" "$PROJECT_DIR/Sources/OutlookBridge.swift" "$PROJECT_DIR/Tests/MailStoreTests.swift" -framework AppKit -o "$TEST_DIR/mail"
"$TEST_DIR/mail"
if [[ "${1:-}" == "--live" ]]; then
    xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/MailStore.swift" "$PROJECT_DIR/Sources/OutlookBridge.swift" "$PROJECT_DIR/Tests/MailIntegration.swift" -framework AppKit -o "$TEST_DIR/live"
    "$TEST_DIR/live" --live
fi
