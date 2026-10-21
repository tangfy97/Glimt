# Contributing to Glimt

Thank you for helping. Bug reports, ideas, translations and code are all welcome. Glimt is deliberately small, so for anything beyond a fix, please open an issue to talk about it before you write the code.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting started

You need macOS 14 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate && open Glimt.xcodeproj
```

The Xcode project is generated from `project.yml`. Change `project.yml`, not the project file, then run `xcodegen generate` again and commit both.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the app is put together. [docs/DESIGN.md](docs/DESIGN.md) explains the principles behind its behaviour and look; please read it before changing anything visible.

## Before you open a pull request

Run the unit tests:

```bash
xcodebuild test -project Glimt.xcodeproj -scheme Glimt -derivedDataPath build/DerivedData.noindex
```

(Build products live in `build/DerivedData.noindex`, which Spotlight skips, so development builds don't show up next to your installed copy in Launchpad or Open With. The scripts also unregister them after use.)

Run the self-test, which drives a real window against real files (move, copy, trash, rename, rotate, tags, undo and redo, folder navigation):

```bash
scripts/selftest.sh
```

If your change touches loading, decoding, the grid or the viewer, run the benchmark before and after and include both results in the pull request ([docs/PERFORMANCE.md](docs/PERFORMANCE.md)):

```bash
scripts/make-fixtures.sh
```

```bash
scripts/bench.sh .fixtures/10k 150 120
```

If your change is visible, include a screenshot. `GLIMT_SNAPSHOT=/tmp/glimt` renders the grid and the viewer to PNG files without screen-recording permission; add `GLIMT_SNAPSHOT_SETTINGS=1` for the Settings panes.

## Code style

- Match the code around you: naming, structure, comment density.
- Swift 6 with complete concurrency checking; no warnings.
- Nothing on the main thread reads files or decodes images.
- Comments explain why, not what. Every type has a one-line summary of its job.
- Apple frameworks only. Please don't add packages.
- Interface text goes through `String(localized:)` (or a SwiftUI string literal) and is short and specific.

Do not copy code from Phoenix Slides or from any other project. Phoenix Slides is licensed under Creative Commons BY-NC-SA, which is not compatible with Glimt's Apache License. Ideas are welcome; code must be your own.

## Translations

Glimt is in English and Simplified Chinese. Adding a language takes one file:

1. Copy `Localization/zh-Hans.json` to `Localization/<code>.json` (for example `nb.json` for Norwegian Bokmål) and translate the values. Keep `%@` and `%lld` placeholders.
2. Add the code to `CFBundleLocalizations` in `Glimt/Info.plist`.
3. Run `scripts/localize.sh`. It updates `Glimt/Localizable.xcstrings` and lists any string still missing.

When you add or change interface text in code, run `scripts/localize.sh` and add the new strings to every file in `Localization/`.

## Commits and pull requests

- One topic per pull request, with a description of what changed and why.
- Commit messages: a short summary line in the imperative ("Keep zoom when paging"), then a blank line and the reasons if they aren't obvious.
- By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE).

## Releases

Maintainers build signed, notarized releases with `scripts/release.sh`; see the comments at the top of the script.
