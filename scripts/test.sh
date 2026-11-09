#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/swift-cache
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Tests/ModelDefinitionsTests.swift \
    -lsqlite3 -framework Security -o .build/model-tests
.build/model-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/NotebookExport.swift Tests/NotebookExportTests.swift \
    -lsqlite3 -o .build/export-tests
.build/export-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Tests/SelectionLookupTests.swift -lsqlite3 -o .build/selection-tests
.build/selection-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/DefinitionCache.swift Sources/NotebookExport.swift Tests/DefinitionCacheTests.swift \
    -lsqlite3 -framework Security -o .build/cache-tests
.build/cache-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/DefinitionCache.swift Sources/TranslationSelection.swift Sources/TranslationMirrors.swift Sources/LocalTranslation.swift Sources/ModelChat.swift Sources/SentenceAnalysis.swift Sources/ReaderState.swift Tests/ReaderStateTests.swift \
    -lsqlite3 -framework Security -o .build/reader-tests
.build/reader-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/TranslationSelection.swift Sources/Theme.swift Sources/ReadingText.swift Tests/ReadingInteractionTests.swift -o .build/interaction-tests
.build/interaction-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Theme.swift Sources/PersistedSplitView.swift Tests/SplitWidthTests.swift -o .build/split-tests
.build/split-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/TranslationMirrors.swift Sources/LocalTranslation.swift Tests/LocalTranslationTests.swift \
    -lsqlite3 -framework Security -o .build/translation-tests
.build/translation-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/MOJiSearch.swift Tests/MOJiSearchTests.swift -o .build/moji-tests
.build/moji-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/ModelChat.swift Sources/SentenceAnalysis.swift Tests/SentenceAnalysisTests.swift \
    -lsqlite3 -framework Security -o .build/analysis-tests
.build/analysis-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/TranslationMirrors.swift Sources/LocalTranslation.swift Tests/TranslationMirrorTests.swift \
    -lsqlite3 -framework Security -o .build/mirror-tests
.build/mirror-tests
swiftc -module-cache-path "$PWD/.build/swift-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    Sources/Core.swift Sources/PartsOfSpeech.swift Sources/ModelDefinitions.swift Sources/ModelChat.swift Tests/ModelChatTests.swift \
    -lsqlite3 -framework Security -o .build/chat-tests
.build/chat-tests
