<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Glimt icon: a low sun over a fjord">
</p>

<h1 align="center">Glimt</h1>

<p align="center">
  A fast, calm image viewer and sorter for macOS.<br>
  Open a folder, look, press a number key, move on.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-informational" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="Apache License 2.0"></a>
</p>

*Glimt* (Norwegian and Danish for "a glimpse, a flash of light") is pronounced like *glimpt* without the p.

Glimt is for going through a lot of pictures quickly: the hundreds from a trip, a shoot, a phone backup, a scanned archive. It opens any folder instantly, pages through full-resolution photos without waiting, and sorts them into folders with the number keys. No import, no library, no catalog: your files stay exactly where they are.

## Why Glimt

- **Instant.** Every picture is decoded off the main thread into GPU-ready memory before you reach it. Turning the page takes about 3 ms; a 10,000-photo folder lists in about 0.2 s.
- **Sorting is the whole point.** Assign up to nine folders to the number keys. Press `1` and the photo moves; its RAW partner, Live Photo movie and `.xmp` sidecar go with it. Everything can be undone.
- **Native and quiet.** Built only on Apple's frameworks: no Electron, no web views, no dependencies. Under 2 MB to download. It never connects to the internet.

## Features

**Browse**
- Folder columns above the grid, in the spirit of Phoenix Slides: places and volumes on the left, the path across, the open folder's pictures below
- Thumbnail grid that resizes under your fingers (pinch, ⌘-scroll, or the slider), with a disk cache so a folder seen once opens instantly
- Sort by name (in Finder order), date modified, created or added, kind, or size; filter to images, videos, or a Finder tag; search by name
- Optionally include every image in subfolders

**Look**
- System pinch-to-zoom, smart zoom, and inertia, as smooth as Preview
- Hold `Z` for a 100% look at the pointer, release to come back
- Keep the same zoom and position while paging, to compare a burst for focus
- RAW files show their embedded preview immediately; zooming in decodes the RAW
- Videos and animated GIF, PNG, WebP and HEIC play inline
- File info on the picture (`I`), and an Info panel (`⌘I`) with camera, lens, exposure and location
- Slideshows: everything, from the selected picture, or only the selected ones; in full screen or in the window; loop and shuffle

**Sort**
- Number keys `1`–`9` move to a folder, `⇧1`–`⇧9` copy, `⌥1`–`⌥9` choose the folder
- A sort bar along the bottom shows which key goes where; drop files on it too
- Move to Trash, rename, lossless rotate and flip (only the EXIF orientation changes), Finder tags with `⌃1`–`⌃7`
- Multi-level undo and redo for every change

**Fit in**
- Native toolbar, menus, full screen, tabs and windows; light and dark appearance
- English and Simplified Chinese, following the system language
- Respects Reduce Motion

## Install

**Download:** get the latest version from [Releases](https://github.com/tangfy97/Glimt/releases), unzip, and drag Glimt to Applications. Glimt needs macOS 14 Sonoma or later.

**Build from source:** you need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate && open Glimt.xcodeproj
```

Then press ⌘R. See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and tools.

## Keyboard

| Key | Action |
|---|---|
| `←` `→` `Space` | Previous / next |
| `Page Up` `Page Down` | Back / forward 10 |
| `Return` / `Esc` | Open in the viewer / back to the grid |
| `1`–`9` | Move to the folder for that key (`⇧` copies) |
| `⌘⌫` | Move to Trash |
| `⌘Z` | Undo |
| `Z` | Hold for 100% |
| `⌘L` `⌘R` | Rotate |
| `I` | File info on the picture |
| `⌥⌘P` | Slideshow |
| `⌘[` `⌘]` `⌘↑` | Back, forward, enclosing folder |

Press `?` in the viewer or ⌘/ anywhere for the full list.

## Performance

Measured on a MacBook Pro (M1 Pro, 32 GB) with 24 and 50 megapixel JPEGs. The numbers are reproducible with the scripts in this repository; see [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

| | Glimt |
|---|---|
| Key press to new photo on screen | 3 ms typical, under 10 ms worst case |
| Holding an arrow key | a picture on every key repeat |
| List a folder of 10,000 photos | ~0.2 s |
| Grid of a folder seen before | ~3 ms to fill the screen |
| Memory when idle | ~19 MB |
| App size | 1.6 MB (1.4 MB zipped) |

## Privacy

Glimt never connects to the internet. There are no accounts, analytics, telemetry, or update checks. It reads the folders you open, writes only the changes you ask for, and keeps a thumbnail cache in `~/Library/Caches`, which you can clear in Settings.

## Contributing

Bug reports, ideas and pull requests are welcome; please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Translations are especially welcome: adding a language is one JSON file. How the app is put together is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the principles behind its look and behaviour are in [docs/DESIGN.md](docs/DESIGN.md).

## Acknowledgements

Glimt is inspired by [Phoenix Slides](https://github.com/gobbledegook/creevey) by Dominic Yu, a much-loved Mac slideshow and sorting tool since 2005. Glimt is an independent reimplementation and shares no code with it.

## License

Copyright © 2026 TangSpark. Released under the [Apache License 2.0](LICENSE).

---

<p align="center">
  Glimt is made by <a href="https://tang-spark.no/?ref=github-glimt"><b>TangSpark</b></a>, a small independent software studio in Norway.<br>
  <i>Small software with northern calm.</i><br>
  Say hello at <a href="mailto:hello@tang-spark.no">hello@tang-spark.no</a>.
</p>
