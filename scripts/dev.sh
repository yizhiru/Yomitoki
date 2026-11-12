#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/.build/dev/读解.app"
if [[ ! -d "$app" ]]; then
    if [[ ! -d "dist/读解.app" ]]; then
        bash scripts/build.sh
    fi
    mkdir -p "$(dirname "$app")"
    ditto "dist/读解.app" "$app"
fi

stage="$(mktemp -d "$PWD/.build/dev/compile.XXXXXX")"
preview_pid=

stop_preview() {
    if [[ -n "$preview_pid" ]]; then
        kill "$preview_pid" 2>/dev/null || true
        wait "$preview_pid" 2>/dev/null || true
        preview_pid=
    fi
}

cleanup() {
    stop_preview
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p .build/swift-cache
compile_preview() {
    swiftc -module-cache-path "$PWD/.build/swift-cache" -target "$(uname -m)-apple-macosx14.0" \
        Sources/*.swift -lsqlite3 -framework Security -o "$stage/Yomitoki"
}

install_preview() {
    # The engine and dictionary remain in the existing bundle.
    python3 scripts/bundle_ebooks.py "$app"
    cp Resources/zh.tsv "$app/Contents/Resources/"
    mv "$stage/Yomitoki" "$app/Contents/MacOS/Yomitoki"
    codesign --force --sign - "$app"
}

source_fingerprint() {
    # Include file contents and names so atomic saves, additions and removals are detected.
    find Sources -maxdepth 1 -type f -name '*.swift' -exec shasum -a 256 {} + | LC_ALL=C sort
}

export YOMITOKI_DATA_DIRECTORY="${YOMITOKI_DATA_DIRECTORY:-$PWD/.build/dev/data}"
if [[ "${1:-}" == "--build-only" ]]; then
    compile_preview
    install_preview
    printf '已更新本地预览 %s\n' "$app"
    exit 0
fi

printf '正在监听 Swift 源码。保存后自动重新编译，按 Ctrl+C 停止。\n'
previous=
while true; do
    if [[ -n "$preview_pid" ]] && ! kill -0 "$preview_pid" 2>/dev/null; then
        exit 0
    fi
    if ! current="$(source_fingerprint)"; then
        sleep 1
        continue
    fi
    if [[ "$current" != "$previous" ]]; then
        previous="$current"
        printf '正在编译预览…\n'
        if compile_preview; then
            if [[ -n "$preview_pid" ]] && ! kill -0 "$preview_pid" 2>/dev/null; then
                exit 0
            fi
            stop_preview
            install_preview
            "$app/Contents/MacOS/Yomitoki" &
            preview_pid=$!
            printf '预览已启动。\n'
        else
            printf '编译失败。保存修正后会自动重试。\n' >&2
        fi
    fi
    sleep 1
done
