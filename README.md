# Glimt

> *glimt* — 挪威语 / 丹麦语里的"一瞥、闪光"。读作 **/ɡlɪmt/**（"格林特"），纯拉丁字母，各国都好念。

原生 macOS 看图与分拣工具，[Phoenix Slides (Creevey)](https://github.com/gobbledegook/creevey) 的现代替代品。
AppKit + ImageIO + Core Animation（设置和信息面板用 SwiftUI，视频用 AVKit），零第三方依赖。界面支持简体中文和英文，跟随系统语言。

和 Phoenix Slides、同类产品的逐项对照，以及设计上的取舍，见 [docs/REVIEW.md](docs/REVIEW.md)。

## 构建

需要 Xcode 16+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。工程文件由 `project.yml` 生成。

```bash
xcodegen generate
```

```bash
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Release -derivedDataPath build/DerivedData.noindex build
```

## 功能

- **网格**：子文件夹在前，缩略图按比例显示；双指捏合 / ⌘+滚轮 / 工具栏滑块改变大小（56 到 480 pt），以指针下的图为锚点；缩略图 256/512/1024 三档，缓存在 `~/Library/Caches`，看过的文件夹再开几毫秒出图。可拖出到 Finder 或其他 app。可选包含子文件夹（⇧⌘F）。
- **看图**：系统级捏合缩放、双指双击智能缩放、惯性与回弹；三级清晰度（内嵌缩略图 → 屏幕尺寸 → 原图）无缝替换；RAW 先显示内嵌预览；方向感知预取；按住方向键时快翻模式；Page Up/Down 跳 10 张。网格 ↔ 看图之间缩略图飞入 / 飞回的转场（开启"减少动态效果"时改为淡入淡出）。
- **检查细节**：按住 Z 在指针处看 100%，松开回去，轻点则保持；翻页时保持缩放（⌥⌘K），用来对比连拍的对焦；大图以实际大小打开（⇧⌘E）；`i` 在图上显示文件名、尺寸、大小，再按一次加相机和曝光；`?` 显示快捷键速查。
- **分拣**：底部分拣栏列出已设置的目标文件夹；数字键移动、⇧数字复制、⌥数字设置目标；点击或拖放到分拣栏也可以；"移到 / 拷贝到 ▸ 其他文件夹……"随时选。RAW+JPEG 同名文件、实况照片视频和 .xmp 附属文件一起移动（可关）。⌘⌫ 移到废纸篓。所有文件操作按顺序执行，都可多级撤销 / 重做。
- **整理**：⌘L / ⌘R 旋转、旋转 180°、水平 / 垂直翻转，全部无损（只改 EXIF 方向，不重新压缩）；重命名（⇧⌘R，配对文件一起改名）；Finder 标签 ⌃1–⌃7 切换、⌃0 清除，网格里显示彩色圆点；设为桌面图片（⌥⌘D）；打开方式、共享。
- **浏览**：按名称 / 修改日期 / 创建日期 / 添加日期 / 种类 / 大小排序，升降序；按类型（图片 / 视频）和标签筛选；⌘F 按文件名搜索；⌘↑ 上层文件夹，⇧⌘G 前往文件夹，"前往"菜单里有常用位置和宗卷；最近打开的文件夹在欢迎页和"打开最近使用"里；⌘N 新窗口、⌘T 新标签页；文件夹变化自动刷新；状态栏显示选中数量和总大小。
- **媒体**：视频内联播放（空格暂停）；GIF / APNG / WebP / HEIC 动图自动播放。
- **幻灯片**：⌥⌘P。没选 = 全部从头，选一张 = 从这张开始，选多张 = 只放选中的；按住 ⌥ 或用菜单可在窗口里放；空格暂停，`[` `]` 调速度，循环、随机播放，Esc 结束。
- **信息面板**（⌘I）：尺寸、色彩配置、相机、镜头、焦距、光圈、快门、ISO、拍摄时间、GPS；视频显示时长、分辨率和帧率。
- **设置**（⌘,）：外观（跟随系统 / 浅色 / 深色）、文件名显示、看图行为、幻灯片、数字键移动或拷贝、RAW+JPEG 成对处理、9 个目标文件夹、缩略图缓存大小与清空、快捷键一览。

快捷键完整列表见 设置 → 快捷键。

## 架构

```
Glimt/
  App/        入口、菜单、偏好设置、分拣目标、Finder 标签
  Library/    Item · FolderScanner（两遍：先文件，后标签）· FolderModel（排序 / 筛选 / 监听）· FileOperations（全部可撤销）
  Pipeline/   ImageDecoder（ImageIO → IOSurface）· DecodePipeline（看图队列与缓存）· ThumbnailStore（缩略图内存 + 磁盘缓存）
  Browser/    GridLayout（O(1) 布局）· ThumbnailCell · BrowserController
  Viewer/     ViewerController · ViewerView · ZoomScrollView · 叠加层
  Window/     MainWindowController（模式切换、转场、工具栏、命令）· 分拣栏 · 信息面板 · 设置
  Support/    signpost、进程指标、Benchmark、SelfTest
Design/icons/ 图标方案（SVG 原稿 + 对比图）
scripts/      测试图生成、跑分、图标安装、本地化同步
Glimt/Localizable.xcstrings  中英文字符串（由 scripts/localize.sh 从源码同步）
```

关键决定：

- **缩放用 `NSScrollView.allowsMagnification`**，每帧只是 GPU 变换。
- **所有位图都在 IOSurface 里**（看图和缩略图）。Core Animation 零拷贝显示，主线程交图几乎零成本，内存里也只有一份。
- **网格布局按下标直接算坐标**，一万项和十项一样快，所以捏合时每个事件都能重排而不掉帧。
- **文件操作先改模型再做 IO**：分拣后界面立刻前进，IO 在后台。撤销项同步登记，所以撤销 / 重做顺序不会被异步打乱。
- **Finder 标签放到第二遍读取**：它读扩展属性，比其他所有信息加起来还慢三倍。
- **不沙盒**（开启 Hardened Runtime）：分拣需要往任意文件夹移动文件。

## 实测

机器：MacBook Pro 14"（M1 Pro 10 核，32 GB）。测试图由 `scripts/make-fixtures.sh` 生成（24 MP / 50 MP JPEG，一万张的文件夹）。

| 指标 | 目标 | 实测 |
|---|---|---|
| 翻页，按键 → 帧提交 | < 16 ms | p50 2.9 ms · p95 4.5 ms · max 7 ms |
| 按住方向键（30 ms 一次） | 每次都有画面 | 200/200，p95 4.3 ms |
| 冷启动 → 窗口 | < 300 ms | 270–295 ms |
| 一万张文件夹列出 | < 1 s | ~205 ms（标签随后在后台读取） |
| 首屏缩略图（24 张，24 MP 原图） | — | 无缓存 ~275 ms · 有缓存 3 ms |
| 实际大小 → 原图清晰（24 MP） | — | ~175 ms |
| 空闲内存 | < 80 MB | 19 MB（M1 时测） |
| 看图时内存 | 有上限 | ~565 MB（看图缓存 ≤ 512 MB + 缩略图 ≤ 160 MB） |
| 安装包 | < 5 MB | 1.6 MB（其中图标约 1.1 MB） |

```bash
scripts/make-fixtures.sh
```

```bash
scripts/bench.sh .fixtures/10k 150 120
```

文件操作的端到端自检（移动 / 复制 / 废纸篓 / 重命名 / 旋转 / 标签及其撤销重做、搜索）：

```bash
GLIMT_SELFTEST=1 build/DerivedData.noindex/Build/Products/Release/Glimt.app/Contents/MacOS/Glimt
```

自检共 33 项，中文和英文界面下都通过。

**尚未验证**：捏合、智能缩放、双指横扫、拖放、转场动画、新的分拣栏和欢迎页的观感需要真机手动操作；"0 掉帧"需要 Instruments 的 Animation Hitches 实测；RAW 内嵌预览这条路径还没有用真实 RAW 文件测过。

## 图标

`Design/icons/` 里有四个方案（`concepts.png` 是对比图）。目前装的是 A「午夜太阳」。换成其他方案：

```bash
scripts/make-icon.sh Design/icons/c-window.svg
```

## 本地化

界面文字全部在 `Glimt/Localizable.xcstrings`。改了界面文字之后运行：

```bash
scripts/localize.sh
```

它会从源码同步字符串，套用 `scripts/translations-zh-Hans.json` 里的中文，并列出还没翻译的条目。

## 已知限制

- 超过 6400 万像素的图会降采样（瓦片渲染未做）。
- 快捷键可查看，但还不能自定义。
- 不能按 EXIF 拍摄时间排序（需要逐个读文件）。
- 包含子文件夹时只监听顶层文件夹的变化，切回窗口时会重新扫描。
