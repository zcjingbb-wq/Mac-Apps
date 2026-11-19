#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "Usage: build-harness.sh <app Resources/Harness directory>"
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
HARNESS_INPUT="$SCRIPT_DIR/HarnessRuntime"
DESTINATION="$1"
NODE_VERSION=v24.22.3
NODE_RELEASE="node-${NODE_VERSION}-darwin-arm64"
NODE_SHA256=1d64136c8a43d648d1b3bad10797a4c995b1ca032d2bde8799de43b37f058fe5
CACHE_DIR="${STASHCAT_HARNESS_BUILD_CACHE:-$HOME/Library/Caches/com.jingzicheng.stashcat/harness-build}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stashcat-harness.XXXXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$CACHE_DIR" "$WORK_DIR/install" "$WORK_DIR/bundle/bin" "$WORK_DIR/bundle/Licenses"
CACHE_DIR="$(cd -- "$CACHE_DIR" && pwd)"
NODE_ARCHIVE="$CACHE_DIR/$NODE_RELEASE.tar.xz"
verify_node_archive() {
    printf '%s  %s\n' "$NODE_SHA256" "$1" | shasum -a 256 -c --status
}
if [[ ! -f "$NODE_ARCHIVE" ]] || ! verify_node_archive "$NODE_ARCHIVE"; then
    curl --fail --silent --show-error --location --retry 2 --max-time 120 \
        "https://nodejs.org/dist/$NODE_VERSION/$NODE_RELEASE.tar.xz" \
        --output "$WORK_DIR/node.tar.xz"
    verify_node_archive "$WORK_DIR/node.tar.xz"
    mv -f -- "$WORK_DIR/node.tar.xz" "$NODE_ARCHIVE"
fi

tar -xf "$NODE_ARCHIVE" -C "$WORK_DIR"
NODE_DIR="$WORK_DIR/$NODE_RELEASE"
cp "$HARNESS_INPUT/package.json" "$HARNESS_INPUT/package-lock.json" "$WORK_DIR/install/"
touch "$WORK_DIR/empty-npmrc"
(
    cd -- "$WORK_DIR/install"
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$WORK_DIR" TMPDIR="$WORK_DIR" \
        "$NODE_DIR/bin/node" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" ci \
        --ignore-scripts --omit=dev --no-audit --no-fund --no-bin-links \
        --registry=https://registry.npmjs.org --userconfig="$WORK_DIR/empty-npmrc" \
        --globalconfig=/dev/null --cache="$CACHE_DIR/npm" --prefer-offline --fetch-retries=2 \
        --fetch-timeout=45000 >&2
)

"$NODE_DIR/bin/node" "$HARNESS_INPUT/select-chat-runtime.mjs" "$WORK_DIR/install"
cp "$NODE_DIR/bin/node" "$WORK_DIR/bundle/bin/"
cp "$NODE_DIR/LICENSE" "$WORK_DIR/bundle/Licenses/Node.js-LICENSE.txt"
cp "$HARNESS_INPUT/chat.patch.yml" "$WORK_DIR/bundle/"
cp "$HARNESS_INPUT"/DeepSeek-Harness-* "$WORK_DIR/bundle/Licenses/"
mv -- "$WORK_DIR/install/node_modules" "$WORK_DIR/bundle/"

codesign --force --sign - "$WORK_DIR/bundle/bin/node" >&2
while IFS= read -r -d '' binary; do
    if [[ "$(file -b -- "$binary")" == Mach-O* ]]; then
        codesign --force --sign - "$binary" >&2
    fi
done < <(find "$WORK_DIR/bundle/node_modules" -type f \( -name '*.node' -o -name '*.dylib' -o -name 'spawn-helper' -o -name 'rg' \) -print0)

EXPECTED_VERSION="$(plutil -extract dependencies.@deepseek-ai/dsh raw "$HARNESS_INPUT/package.json")"
ACTUAL_VERSION="$("$WORK_DIR/bundle/bin/node" "$WORK_DIR/bundle/node_modules/@deepseek-ai/dsh/lib/bin.js" --version)"
if [[ "$EXPECTED_VERSION" != "$ACTUAL_VERSION" ]]; then
    print -u2 "Expected DeepSeek Harness $EXPECTED_VERSION, found $ACTUAL_VERSION"
    exit 1
fi

mkdir -p -- "$DESTINATION"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$WORK_DIR/bundle" "$DESTINATION"
