# Mac App Store

The App Store version is the `AppStore` build configuration: the same code as the GitHub release, run in the App Sandbox. The sandbox only lets Glimt into folders the user has chosen, so `FolderAccess` keeps a security-scoped bookmark for each one, and the window shows **Allow Access…** for a folder it can't read yet. Pictures, Movies and Downloads are open from the start through entitlements ([Glimt-AppStore.entitlements](../Glimt/Glimt-AppStore.entitlements)).

## Building and uploading

```bash
scripts/selftest.sh AppStore
```

```bash
scripts/appstore.sh 0.1.0 1 upload
```

The second argument is the build number, which must go up with every upload. Without `upload` the script stops at a signed `build/appstore/Glimt.pkg`.

## App Store Connect

| Field | Value |
|---|---|
| App Store Connect | Apple ID 6825414107 |
| Bundle ID | `com.feiyangtang.Glimt` |
| SKU | `glimt-macos` |
| Primary category | Photo & Video |
| Secondary category | Utilities |
| Price | Free |
| Age rating | 4+ (no objectionable content) |
| App Privacy | Data Not Collected |
| Export compliance | No encryption (`ITSAppUsesNonExemptEncryption` is false) |
| Copyright | 2026 TangSpark |
| Support URL | https://github.com/tangfy97/Glimt/issues |
| Marketing URL | https://tang-spark.no/?ref=appstore-glimt |
| Privacy Policy URL | https://github.com/tangfy97/Glimt/blob/main/PRIVACY.md |

### English (U.S.)

**Name** (30): Glimt – Photo Viewer & Sorter (plain "Glimt" is taken on the App Store)

**Subtitle** (30): Fast photo viewer and sorter

**Promotional text** (170):
Open a folder, look, press a number key, move on. Glimt pages through full-resolution photos instantly and sorts them into folders as you go.

**Keywords** (100):
image viewer,photo culling,sort photos,RAW,slideshow,picture,browser,JPEG,HEIC,cull,folders,quick

**Description**:

Glimt is a fast, calm image viewer and sorter for going through a lot of pictures quickly: the hundreds from a trip, a shoot, a phone backup or a scanned archive.

Open any folder and Glimt shows it at once. Page through full-resolution photos without waiting: each picture is ready before you reach it. Then sort as you look. Give up to nine folders a number key, press 1, and the photo moves there, with its RAW partner, Live Photo movie and sidecar file. Every change can be undone.

No import, no library, no catalog. Your files stay where they are.

BROWSE
• Folder columns above the grid, with your places and drives on the left
• A thumbnail grid you resize with a pinch, cached so a folder opens instantly the second time
• Sort by name, date or size; filter by kind or Finder tag; search by name

LOOK
• Pinch to zoom, smart zoom and inertia, as smooth as Preview
• Hold Z for a 100% look at the pointer
• Keep the same zoom while paging, to compare a burst for focus
• RAW files open on their embedded preview immediately
• Videos and animated images play inline
• Camera, lens, exposure and location in the Info panel
• Slideshows of everything or just the selection

SORT
• Number keys move to a folder; Shift copies
• A sort bar shows which key goes where
• Rename, lossless rotate and flip, Finder tags, Move to Trash
• Multi-level undo and redo

FITS IN
• Native Mac app: toolbar, full screen, tabs, light and dark
• English and Simplified Chinese
• About 2 MB, with no internet connection at all: no accounts, no tracking

Glimt is free and open source under the Apache License 2.0. It is made by TangSpark, a small software studio in Norway.

**What's New** (0.1.0): First version on the Mac App Store.

### Simplified Chinese

**名称**：Glimt – 看图与照片分拣

**副标题**（30）：快速翻看，数字键分拣

**推广文本**（170）：
打开文件夹，看一眼，按数字键，下一张。Glimt 翻看全尺寸照片无需等待，边看边把照片分拣进文件夹。

**关键词**（100）：
看图,图片浏览,照片分拣,选片,整理照片,RAW,幻灯片,相片,JPEG,HEIC,文件夹,快速

**描述**：

Glimt 是一款快速、安静的看图与分拣工具，适合一口气过完大量照片：旅行、拍摄、手机备份或扫描的老照片。

打开任意文件夹，立刻就能看。翻看全尺寸照片无需等待：每张照片在你翻到之前就已经准备好了。边看边分拣：给最多九个文件夹分配数字键，按 1，照片就移过去，连同它的 RAW 原片、实况照片视频和附属文件。每一步都可以撤销。

不用导入，没有图库，也没有目录。文件始终留在原处。

浏览
• 网格上方的文件夹分栏，左侧是常用位置和磁盘
• 双指缩放缩略图网格；看过的文件夹第二次打开瞬间完成
• 按名称、日期或大小排序；按类型或访达标签筛选；按名称搜索

看图
• 双指缩放、智能缩放和惯性滚动，和“预览”一样流畅
• 按住 Z 以 100% 查看指针处细节
• 翻页时保持缩放位置，方便对比连拍的对焦
• RAW 文件立即显示内嵌预览
• 视频和动图直接播放
• 信息面板显示相机、镜头、曝光和位置
• 幻灯片可播放全部或仅所选照片

分拣
• 数字键移动到文件夹，按住 Shift 则复制
• 底部分拣栏显示每个数字键对应的文件夹
• 重命名、无损旋转和翻转、访达标签、移到废纸篓
• 多级撤销和重做

融入 Mac
• 原生 Mac 应用：工具栏、全屏、标签页、浅色和深色模式
• 英文和简体中文
• 约 2 MB，完全不联网：无账号，无追踪

Glimt 免费开源，采用 Apache License 2.0 许可，由挪威的小型软件工作室 TangSpark 制作。

**新功能**（0.1.0）：首次登陆 Mac App Store。

## Notes for App Review

> Glimt is an image viewer and sorter. It needs no account and has no in-app purchases.
>
> It runs in the App Sandbox. Pictures, Movies and Downloads open directly. For any other folder, the window shows "Allow Access…", which opens a standard open panel on that folder; once allowed, the folder is remembered with a security-scoped bookmark. "Allow Access to Home Folder…" on the welcome screen allows everything at once.
>
> To try sorting: open a folder of photos, press 1 and choose any folder when asked; the photo moves there. Press ⌘Z to undo.
>
> The app is open source: https://github.com/tangfy97/Glimt

## Screenshots

At least one, at 2880 × 1800 (or 2560 × 1600, 1440 × 900, 1280 × 800). Use photos the studio owns the rights to: the grid with folder columns, the viewer, the viewer with the Info panel, and the sort bar mid-sort.
