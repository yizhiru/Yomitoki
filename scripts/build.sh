#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version='3.6.2%2B20261026175559'
sha='809d104fe3c1e0ab328ff265bdc52b5eed1f9b669088fd199ef4e713812958a3'
archive="${JMDICT_ARCHIVE:-$PWD/.build/data/jmdict.tgz}"
database="$PWD/.build/data/jmdict-$sha.sqlite"
mkdir -p .build/data .build/swift-cache dist

if [[ ! -f "$database" ]]; then
    if [[ ! -f "$archive" && -z "${JMDICT_ARCHIVE:-}" ]]; then
        curl --fail --location --retry 2 --output "$archive.download" \
            "https://github.com/scriptin/jmdict-simplified/releases/download/$version/jmdict-eng-$version.json.tgz"
        mv "$archive.download" "$archive"
    fi
    if [[ ! -f "$archive" || "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$sha" ]]; then
        echo "JMdict 下载文件的校验和有误。请核对 JMDICT_ARCHIVE，或删除损坏的缓存后重试。" >&2
        exit 1
    fi
    python3 scripts/build_dictionary.py "$archive" "$database"
fi

stage="$(mktemp -d "$PWD/.build/app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/读解.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"
cp -R Resources/Dictionary Resources/zh.tsv "$app/Contents/Resources/"
cp Resources/AppIcon.png "$app/Contents/Resources/"
bash scripts/build_icon.sh "$app/Contents/Resources/AppIcon.icns"
python3 scripts/bundle_ebooks.py "$app"
cp "$database" "$app/Contents/Resources/jmdict.sqlite"
swiftc -module-cache-path "$PWD/.build/swift-cache" -target "$(uname -m)-apple-macosx14.0" -O \
    Sources/Core.swift Sources/EbookImport.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/DefinitionCache.swift Sources/NotebookExport.swift Sources/MOJiSearch.swift Sources/TranslationSelection.swift Sources/TranslationMirrors.swift Sources/LocalTranslation.swift Sources/TranslationViews.swift Sources/ModelChat.swift Sources/SentenceAnalysis.swift Sources/SentenceAnalysisView.swift Sources/ModelChatView.swift Sources/ImportedDictionaries.swift Sources/ReaderState.swift Sources/ReadingText.swift Sources/PersistedSplitView.swift Sources/Theme.swift Sources/Reader.swift -lsqlite3 -framework Security -o "$app/Contents/MacOS/Yomitoki"
python3 scripts/bundle_llama.py "$app" --arch "$(uname -m)"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
rm -rf "dist/读解.app"
mv "$app" "dist/读解.app"
# Remove the previous build only after its replacement has been created successfully.
rm -rf "dist/文拾词.app" "dist/文脉.app"
printf '已生成 %s\n' "$PWD/dist/读解.app"
