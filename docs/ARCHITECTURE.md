# Architecture

Glimt is a single-target AppKit app written in Swift 6 with strict concurrency. It depends only on Apple frameworks: AppKit, ImageIO, Core Animation, IOSurface, AVFoundation/AVKit, and SwiftUI for the Settings and Info panels. There are no packages.

## Source layout

```
Glimt/
  App/        Entry point, menus, preferences, sort targets, Finder tags, app identity and links
  Library/    Item, FolderScanner, FolderModel, FileOperations (every change to files, with undo)
  Pipeline/   ImageDecoder, DecodePipeline (viewer), ThumbnailStore (grid, memory + disk cache)
  Browser/    Thumbnail grid (layout, cells, controller) and the folder columns
  Viewer/     ViewerController, ViewerView, zooming scroll view, overlays, shortcut list
  Window/     MainWindowController (split by concern), RootView, sort bar, Info panel, Settings
  Support/    Signposts, process metrics, and the developer tools: Benchmark, SelfTest, Snapshot
GlimtTests/   Unit tests (XCTest)
Localization/ Translations, one JSON file per language
scripts/      Fixtures, benchmark, self-test, localization sync, icon, release
docs/         This file, design notes, performance notes, design assets
```

The Xcode project is generated from `project.yml` by XcodeGen and is checked in so that `git clone` and open works too.

## The window

One `MainWindowController` per window owns:

- a `FolderModel`: the open folder's items, sorted and filtered, watched for changes;
- a `BrowserController`: the thumbnail grid;
- a `FolderBrowserController`: the folder columns above the grid;
- a `ViewerController`: single-image viewing, video, animation, slideshow;
- a `FileOperations`: every change to files, each registered with the window's undo manager;
- the sort bar and the Info panel.

`RootView` stacks the folder columns, the grid and the viewer in the same space and lays out the bottom bar. The grid and the viewer both read from the same `FolderModel`; opening a picture swaps which one is visible, with a transition that flies the thumbnail to its place in the viewer.

The controller is split across files by concern: `MainWindowController.swift` (window, opening, mode switching, transitions), `+Commands` (menu commands and their validation), `+Delegates` (grid, viewer and sort bar callbacks), `+Toolbar`.

## Folders and files

`FolderScanner` lists a folder off the main thread in two passes: names, kinds, sizes and dates first, so the grid appears at once; Finder tags second, because reading extended attributes costs more than everything else together. Item URLs are always built from the folder URL the model resolved, so paths compare by plain string even where the file system reports `/private/var` for `/var`.

`FolderModel` keeps the full list, a sorted copy, and the filtered `folders` and `media` lists the views show. It watches the folder with a dispatch source and rescans after a short debounce. Observers get `.reloaded` or `.renamed(from:to:)`, so the viewer can keep its place when the current file is renamed.

`FileOperations` updates the model first, so the interface moves on immediately, then performs the work on one serial queue, in the order operations were issued. Each operation registers its inverse with the undo manager synchronously. That is what makes undo and redo correct even while work is still in flight. Work is queued synchronously at the call site: starting a `Task` first would let two operations issued back to back reach the queue in either order.

RAW+JPEG pairs, Live Photo movies and `.xmp`/`.aae` sidecars are found by base name and moved, copied, renamed and trashed together.

## Images

`ImageDecoder` turns a file into an `IOSurface` in display-ready BGRA. Core Animation displays an IOSurface without copying it, so handing a decoded image to the screen costs almost nothing on the main thread, and the cache holds the only copy of the pixels.

Each picture climbs three rungs, and the viewer always shows the best one it has:

| Rung | Source | Typical cost |
|---|---|---|
| `quick` | the embedded EXIF/HEIC thumbnail only | well under 1 ms |
| `preview` | aspect-fit to the screen's pixels; for RAW, the embedded JPEG preview | 20–80 ms |
| `full` | native resolution, capped at 64 MP and 16,384 px per side | 100–300 ms |

`DecodePipeline` keeps exactly the work the viewer wants in flight: the current picture's rungs, then neighbours biased towards the direction of travel. Anything paged past is cancelled. When key repeat outruns decoding, it switches to a rapid mode that runs eight embedded thumbnails ahead. The cache is a byte-limited LRU (1/16 of RAM, between 192 and 512 MB) that never evicts what is on screen and releases everything else under memory pressure.

`ThumbnailStore` produces 256, 512 and 1024 px thumbnails for the grid, keeps them in memory by byte cost, and caches them on disk under `~/Library/Caches/<bundle id>/Thumbnails`, keyed by path, modification time and size. Video thumbnails come from AVFoundation.

## Zooming

The viewer is an `NSScrollView` with magnification enabled, so pinch, smart zoom, inertia and rubber-banding are the system's own. The document view is a single layer whose frame is the source's pixel size; switching rungs only swaps the layer's contents. A full-resolution decode starts as soon as a pinch begins, and the swap waits until the fingers lift. Keyboard and smart-zoom animations are driven by a display link and interpolate in log space.

The grid uses its own `NSCollectionViewLayout` in which every frame is arithmetic on the item index, so a pinch can change the tile size on every event, even in a 10,000-item folder.

## Localization

All interface strings go through `String(localized:)` or SwiftUI string literals and live in `Glimt/Localizable.xcstrings`. Translations are kept as plain JSON in `Localization/<language>.json` and merged into the catalog by `scripts/localize.sh`, which also lists anything untranslated. See [CONTRIBUTING.md](../CONTRIBUTING.md#translations).

## Testing and tools

- **Unit tests** (`GlimtTests`, `xcodebuild test`): orientation math, the byte-limited cache, decoder sizing and EXIF handling, folder scanning, sorting, filtering and RAW pairing.
- **Self-test** (`scripts/selftest.sh`, `GLIMT_SELFTEST=1`): drives a real window against real files in a temporary folder: move, copy, trash, rename, rotate, flip, tags, each with undo and redo; folder columns, arrow keys, history, search, subfolders.
- **Benchmark** (`scripts/bench.sh`, `GLIMT_BENCH=<turns>`): page-turn latency to the Core Animation commit, folder scan, grid fill, full-resolution swap, memory.
- **Snapshot** (`GLIMT_SNAPSHOT=<prefix>`): renders the grid, the viewer and, with `GLIMT_SNAPSHOT_SETTINGS=1`, the Settings panes to PNG files for design review, without screen-recording permission.
- **Signposts**: `Decode` and `Page Turn` intervals appear under Points of Interest in Instruments.
