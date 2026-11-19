#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
TASK_SDK_PATH="${STASHCAT_SDK_PATH:-$(xcrun --show-sdk-path)}"
if [[ -z "${STASHCAT_SDK_PATH:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    TASK_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
TEST_DIR=$(mktemp -d /tmp/StashCat-tests.XXXXXX)
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/Calculus.swift" "$PROJECT_DIR/Tests/CalculusTests.swift" -o "$TEST_DIR/calculus"
"$TEST_DIR/calculus"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/ShelfStore.swift" "$PROJECT_DIR/Tests/ShelfStoreTests.swift" -framework AppKit -o "$TEST_DIR/shelf"
"$TEST_DIR/shelf"
xcrun swiftc -warnings-as-errors -parse-as-library -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/ArchiveService.swift" "$PROJECT_DIR/Tests/ArchiveServiceTests.swift" -o "$TEST_DIR/archive"
"$TEST_DIR/archive"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/CodexUsage.swift" "$PROJECT_DIR/Tests/CodexUsageTests.swift" -o "$TEST_DIR/codex-usage"
"$TEST_DIR/codex-usage"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/AIService.swift" "$PROJECT_DIR/Sources/DeepSeekHarness.swift" "$PROJECT_DIR/Sources/CodexUsage.swift" "$PROJECT_DIR/Sources/CodexService.swift" "$PROJECT_DIR/Tests/CodexServiceTests.swift" -framework AppKit -framework Security -o "$TEST_DIR/codex"
"$TEST_DIR/codex" "$PROJECT_DIR"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/AIService.swift" "$PROJECT_DIR/Sources/DeepSeekHarness.swift" "$PROJECT_DIR/Sources/CodexUsage.swift" "$PROJECT_DIR/Sources/CodexService.swift" "$PROJECT_DIR/Sources/ChatCoordinator.swift" "$PROJECT_DIR/Sources/Calculus.swift" "$PROJECT_DIR/Tests/ChatCoordinatorTests.swift" -framework AppKit -framework Security -o "$TEST_DIR/coordinator"
"$TEST_DIR/coordinator" "$PROJECT_DIR"
xcrun swiftc -warnings-as-errors -parse-as-library -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/ReminderStore.swift" "$PROJECT_DIR/Tests/ReminderStoreTests.swift" -framework AppKit -framework UserNotifications -o "$TEST_DIR/reminders"
"$TEST_DIR/reminders"
xcrun swiftc -warnings-as-errors -parse-as-library -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/VoiceInputService.swift" "$PROJECT_DIR/Tests/VoiceInputTests.swift" -framework Speech -framework AVFoundation -o "$TEST_DIR/voice-input"
"$TEST_DIR/voice-input"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/AttachmentStore.swift" "$PROJECT_DIR/Tests/AttachmentStoreTests.swift" -framework AppKit -framework PDFKit -framework Vision -framework ImageIO -o "$TEST_DIR/attachments"
"$TEST_DIR/attachments"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/AttachmentStore.swift" "$PROJECT_DIR/Sources/AttachmentPrompt.swift" "$PROJECT_DIR/Tests/AttachmentPromptTests.swift" -framework AppKit -framework PDFKit -framework Vision -framework ImageIO -o "$TEST_DIR/prompt"
"$TEST_DIR/prompt"
xcrun swiftc -warnings-as-errors -parse-as-library -sdk "$TASK_SDK_PATH" -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/ScreenCaptureService.swift" "$PROJECT_DIR/Tests/ScreenCaptureTests.swift" -framework AppKit -framework ScreenCaptureKit -framework ImageIO -o "$TEST_DIR/screen-capture"
"$TEST_DIR/screen-capture"
xcrun swiftc -warnings-as-errors -parse-as-library "$PROJECT_DIR/Sources/AttachmentStore.swift" "$PROJECT_DIR/Sources/AttachmentPrompt.swift" "$PROJECT_DIR/Sources/ScreenQuestionService.swift" "$PROJECT_DIR/Tests/ScreenQuestionTests.swift" -framework AppKit -framework PDFKit -framework Vision -framework ImageIO -o "$TEST_DIR/screen-question"
"$TEST_DIR/screen-question"
xcrun swiftc -warnings-as-errors -parse-as-library -sdk "$TASK_SDK_PATH" -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/ScreenSessionCapture.swift" "$PROJECT_DIR/Tests/ScreenSessionCaptureTests.swift" -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO -o "$TEST_DIR/screen-session"
"$TEST_DIR/screen-session"
xcrun swiftc -warnings-as-errors -parse-as-library -sdk "$TASK_SDK_PATH" -target arm64-apple-macos14.0 "$PROJECT_DIR/Sources/AIService.swift" "$PROJECT_DIR/Sources/DeepSeekHarness.swift" "$PROJECT_DIR/Sources/CodexUsage.swift" "$PROJECT_DIR/Sources/CodexService.swift" "$PROJECT_DIR/Sources/ChatCoordinator.swift" "$PROJECT_DIR/Sources/Calculus.swift" "$PROJECT_DIR/Sources/AttachmentStore.swift" "$PROJECT_DIR/Sources/AttachmentPrompt.swift" "$PROJECT_DIR/Sources/ScreenQuestionService.swift" "$PROJECT_DIR/Sources/ScreenSessionCapture.swift" "$PROJECT_DIR/Sources/ScreenSessionAssistant.swift" "$PROJECT_DIR/Tests/ScreenSessionAssistantTests.swift" -framework AppKit -framework PDFKit -framework Vision -framework ImageIO -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreImage -framework Security -o "$TEST_DIR/screen-assistant"
"$TEST_DIR/screen-assistant" "$PROJECT_DIR"
zsh "$SCRIPT_DIR/outlook-tests.sh"
