# Changelog

All notable changes to Glimt are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- A Mac App Store version that runs in the App Sandbox. Glimt asks once for each folder outside Pictures, Movies and Downloads, or once for the whole home folder, and remembers the answer.

## [0.1.1] - 2026-10-21

### Fixed
- Recent folders on the welcome screen showed only "…".

### Added
- A privacy policy ([PRIVACY.md](PRIVACY.md)) and a privacy manifest. Glimt still collects nothing.

## [0.1.0] - 2026-10-21

The first public version.

### Browse
- Folder columns above the grid with places and volumes, type-to-select and arrow-key navigation.
- Thumbnail grid with pinch-to-resize, a disk cache, sorting, filtering by kind and Finder tag, search, and optional subfolders.
- Back and forward through visited folders; multiple windows and tabs.

### Look
- Three-stage decoding (embedded thumbnail, screen size, full resolution) into GPU-ready memory; page turns in about 3 ms.
- System pinch-to-zoom, smart zoom, hold-Z loupe, keep zoom while paging, open large images at 100%.
- Embedded previews for RAW files; inline video and animated images.
- File info on the picture, an Info panel with camera and exposure details, and slideshows that respect the selection.

### Sort
- Nine number-key sort folders, a sort bar, Move to Trash, rename, lossless rotate and flip, Finder tags.
- RAW+JPEG pairs, Live Photo movies and sidecars stay together.
- Undo and redo for every change.

### Fit in
- English and Simplified Chinese; light and dark appearance; Reduce Motion support.

[Unreleased]: https://github.com/tangfy97/Glimt/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/tangfy97/Glimt/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tangfy97/Glimt/releases/tag/v0.1.0
