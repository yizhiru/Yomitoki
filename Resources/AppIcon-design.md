# 读解应用图标

以展开的书页代表阅读，以右页的一道留白表示阅读高亮。浅灰紫底板搭配深灰靛蓝书页，用双色保持小尺寸下的清晰对比。书页约占底板宽度的四分之三。圆角底板外保留透明区域。

- 生成方式：内置 image_gen 工具，基于原图调整配色和书页比例，保留透明背景。
- 源图：`Resources/AppIcon.png`。
- 构建：`scripts/build_icon.sh` 生成 16、32、128、256、512 点的标准和 Retina 图标，最高分辨率为 1024 × 1024，打包到应用的 `Contents/Resources/AppIcon.icns`。
- 配置：`Resources/Info.plist` 的 `CFBundleIconFile` 指向 `AppIcon`。
- 运行时直接用随附的 PNG 源图设置 [`NSApplication.applicationIconImage`](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)，让 Dock 使用原始设计。Finder 等位置仍由系统按自身样式渲染。
- 构建工具：macOS 自带的 `sips` 和 `iconutil`，无需额外安装依赖。

## 最终生成提示词

```text
Use case: precise-object-edit. Asset: Yomitoki macOS and Windows app icon. Edit target: provided icon. Change only the palette and surface finish. Use exactly two flat colors: very pale lavender-gray (#E9EAF5) for the rounded square tile and muted slate-indigo (#41466C) for the two open-book pages. Keep the existing short pill-shaped reading highlight in the same place on the right page, as a cutout in the tile color. Preserve the silhouette, centered composition, shape proportions and even transparent padding. Clean antialiasing, actual alpha outside the tile, no gradients, textures, shadows, rims, text or added motifs. One square production PNG.
```

```text
Edit the supplied two-color Yomitoki app icon. Enlarge the central open-book symbol and its small pill-shaped highlight together by 25% about its center, increasing its width from roughly 60% to 75% of the rounded tile. Preserve the exact tile size, continuous rounded corner silhouette, transparent outer padding, centered book, book shape and negative-space highlight on its right page. Keep the very pale lavender-gray tile and dark gray-indigo glyph, with clean flat fills. Crisp clean antialiasing, real transparent alpha outside tile, no white fringe or stray pixels, no new elements or text. Square PNG.
```
