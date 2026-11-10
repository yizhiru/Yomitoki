#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/dist/读解.app}"
mkdir -p .build/swift-cache .build/ebook-regression
swiftc -module-cache-path "$PWD/.build/swift-cache" -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/EbookImport.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/DefinitionCache.swift \
    Sources/NotebookExport.swift Sources/TranslationSelection.swift Sources/TranslationMirrors.swift Sources/LocalTranslation.swift \
    Sources/ModelChat.swift Sources/SentenceAnalysis.swift Sources/ReaderState.swift Tests/EbookImportTests.swift \
    -lsqlite3 -framework Security -o .build/ebook-regression-tests
# Deny both known Calibre installations, even on development machines which have it installed.
profile="(version 1)(allow default)(deny file-read* process-exec (subpath \"/Applications/calibre.app\") (subpath \"$HOME/Applications/calibre.app\"))"
PATH=/usr/bin:/bin /usr/bin/sandbox-exec -p "$profile" "$PWD/.build/ebook-regression-tests" \
    "$PWD/desktop/tests/fixtures/ebooks" "$app/Contents/Resources" "$PWD/.build/ebook-regression/native-cases.json"
# Repeat using Bundle.main inside a signed .app moved to a path with spaces and Japanese text.
stage="$(mktemp -d "$PWD/.build/ebook-regression/日本語 Book QA.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
moved="$stage/読解 Test.app"
ditto "$app" "$moved"
cp .build/ebook-regression-tests "$moved/Contents/MacOS/Yomitoki"
codesign --force --sign - "$moved"
codesign --verify --deep --strict "$moved"
PATH=/usr/bin:/bin /usr/bin/sandbox-exec -p "$profile" "$moved/Contents/MacOS/Yomitoki" \
    "$PWD/desktop/tests/fixtures/ebooks" --bundled "$PWD/.build/ebook-regression/packaged-cases.json"
