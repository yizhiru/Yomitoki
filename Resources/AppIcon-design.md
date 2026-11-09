# 读解应用图标

以展开的书页代表阅读，以一笔朱红色高亮代表细读、理解和探究。深靛蓝与米白色形成清晰对比，避免文字在小尺寸下变得难以辨认。圆角底板外保留透明区域。

- 生成方式：内置 image_gen 工具，透明背景。
- 源图：`Resources/AppIcon.png`。
- 构建：`scripts/build_icon.sh` 生成 16、32、128、256、512 点的标准和 Retina 图标，最高分辨率为 1024 × 1024，打包到应用的 `Contents/Resources/AppIcon.icns`。
- 配置：`Resources/Info.plist` 的 `CFBundleIconFile` 指向 `AppIcon`。
- 运行时直接用随附的 PNG 源图设置 [`NSApplication.applicationIconImage`](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)，让 Dock 使用原始设计。Finder 等位置仍由系统按自身样式渲染。
- 构建工具：macOS 自带的 `sips` 和 `iconutil`，无需额外安装依赖。

## 最终生成提示词

```text
Use case: logo-brand.
Asset type: final production macOS application icon for 读解 / Yomitoki, a Japanese deep-reading application.
Primary request: one elegant, exceptionally simple and recognizable app icon combining a book and a reading focus. A single warm ivory open-book glyph, built from just two solid clean facing page shapes and a slim center gutter, on a muted deep ink-indigo rounded-square tile. On the right-hand page, one short muted vermilion horizontal highlight, conveying close reading and insight. Quiet Japanese editorial sensibility, generous negative space, balanced proportions, crisp optical alignment.
Style: refined flat vector-like shapes, restrained gentle depth only on the tile edge, no illustration, no paper texture.
Composition: one centered icon only on a square 1024 by 1024 canvas. Tile occupies about 82 percent of canvas width, with macOS-style continuous rounded corners and even transparent padding on all sides; book occupies about 55 percent of tile width. Thick simple shapes that read clearly at 16, 32, 64 pixels. Actual transparent alpha outside the rounded tile, no opaque outer square or checkerboard.
Text: none. No letters, kanji, hiragana or app name.
Avoid: magnifying glasses, sparkles, robots, chat bubbles, flags, circles representing a sun, multiple competing symbols, long shadows, busy decorative details, mockups, grids, multiple variants, labels, watermarks. Deliver the icon itself as a single finished transparent PNG.
```
