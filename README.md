# Glimt

> *glimt* — 挪威语 / 丹麦语里的"一瞥、闪光"。读作 **/ɡlɪmt/**（"格林特"），纯拉丁字母，各国都好念。

一个原生 macOS 看图与分拣工具，[Phoenix Slides (Creevey)](https://github.com/gobbledegook/creevey) 的现代替代品。
纯 AppKit + ImageIO + Core Animation，零第三方依赖。

## 构建

需要 Xcode 16+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。工程文件由 `project.yml` 生成。

```bash
xcodegen generate
```

```bash
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Release -derivedDataPath build/dd build
```

或直接 `open Glimt.xcodeproj` 后 ⌘R。

## 用法（M1）

| 操作 | 按键 / 手势 |
|---|---|
| 打开文件夹或图片 | ⌘O，或拖到窗口 / Dock 图标上；启动时自动回到上次位置 |
| 翻页 | ← →、空格 / ⇧空格、PageUp/PageDown；适配窗口时 ↑ ↓、鼠标滚轮、双指横扫也翻页 |
| 首张 / 末张 | Home / End |
| 缩放 | 双指捏合；双指双击智能缩放；⌘= / ⌘-；⌥ 或 ⌘ + 滚轮以指针为中心缩放 |
| 实际大小 / 适配窗口 | ⌘0 / ⌘9；Esc 回到适配 |
| 放大后平移 | 双指拖动；↑ ↓ |
| 全屏 | F 或 ⌃⌘F；Esc 退出 |

## 架构

```
Glimt/
  App/        入口、菜单（纯代码，无 storyboard）
  Viewer/     ViewerWindowController（文件列表、调度）· ViewerView（缩放、键盘、拖放）
              ZoomScrollView（NSScrollView 缩放、居中 ClipView、图层画布、缩放动画）
  Pipeline/   ImageDecoder（ImageIO → IOSurface）· DecodePipeline（队列、取消、按字节 LRU）
  Library/    FolderScanner
  Support/    signpost、进程指标、Benchmark
```

关键决定：

- **缩放用系统 `NSScrollView.allowsMagnification`**，不用 SwiftUI 手势。捏合、惯性、回弹、以手指为中心都由系统合成，每帧只是 GPU 变换。
- **解码结果直接放进 IOSurface。** Core Animation 显示 IOSurface 零拷贝，所以主线程交图几乎零成本，缓存里也只有一份像素。（最初用 CGImage：翻页 20 ms、内存 1.6 GB，因为 CA 会再拷一份。）
- **三级清晰度阶梯**：`quick`（文件内嵌缩略图，几毫秒）→ `preview`（按屏幕像素等比）→ `full`（原图，上限 6400 万像素 / 16384 px）。同一张图只升不降；画布尺寸始终是原图像素尺寸，换清晰度只换 contents，画面不跳。捏合一开始就启动原图解码，手指松开再换纹理；缩回适配时换回 preview（滤波更好、可释放原图）。
- **预取按方向偏置**：前进时 +1 +2 +3 / −1 −2；划过去的任务立即取消。按住方向键（< 150 ms 一次）时切到"快翻模式"：向前 8 张只读内嵌缩略图，没有就显示空白，不显示旧图冒充新图。
- **缓存按字节计费**：物理内存 / 16，夹在 192–512 MB 之间；当前要用的永不被淘汰；系统内存压力时清掉其余。
- **不沙盒**：分拣需要读同目录、往任意文件夹移动文件。开启 Hardened Runtime。

## 性能（M1 实测）

机器：MacBook Pro 14"（M1 Pro 10 核，32 GB，3024×1964 ProMotion）。测试图由 `scripts/make-fixtures.sh` 生成。

| 指标 | 目标 | 实测 |
|---|---|---|
| 翻页，按键 → 帧提交给渲染服务器 | < 16 ms | p50 2.1 ms · p95 3.7 ms · max 5.4 ms（150 次，24 MP JPEG） |
| 按住方向键（30 ms 一次） | 每次都有画面 | 200/200 次出画面，p95 3.4 ms |
| 冷启动 → 窗口 | < 300 ms | 185–210 ms（含 dyld） |
| 一万张文件夹列出 + 排序 | < 1 s | 135 ms |
| 实际大小 → 原图清晰 | — | 24 MP 约 190 ms |
| 空闲内存 | < 80 MB | 19 MB |
| 看图时内存 | 有上限 | 约 530 MB（缓存上限 512 MB） |
| 安装包 | < 5 MB | 476 KB |

复现：

```bash
scripts/make-fixtures.sh
```

```bash
scripts/bench.sh .fixtures/10k 150 120
```

`GLIMT_BENCH_VERBOSE=1` 会逐条打印超过 8 ms 的翻页。Instruments 里 Points of Interest 有 `Decode` 和 `Page Turn` 两个区间。

**尚未验证**：捏合、智能缩放、双指横扫这些手势需要真机手动操作；"0 掉帧"需要用 Instruments 的 Animation Hitches 模板实测。

## 已知限制 / 下一步

- 超过 6400 万像素的图会降采样到这个上限；瓦片渲染还没做。
- 没有 App 图标；界面文字是英文（已用 `String(localized:)`，可直接加 String Catalog）。
- 文件夹变化（新增、删除）不会自动刷新。
- 里程碑见 [docs/PLAN.md](docs/PLAN.md)。
