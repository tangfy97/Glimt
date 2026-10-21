#!/bin/zsh
# Refreshes Glimt/Localizable.xcstrings from the source code and applies the translations in
# Localization/<language>.json (one file per language, English key → translation).
# Prints every string that still needs a translation.
#
# To add a language: create Localization/<code>.json (copy zh-Hans.json and translate the
# values), add <code> to CFBundleLocalizations in Glimt/Info.plist, and run this script.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Debug -derivedDataPath build/DerivedData.noindex build -quiet
stringsdata=(build/DerivedData.noindex/Build/Intermediates.noindex/Glimt.build/Debug/Glimt.build/Objects-normal/*/*.stringsdata)
args=()
for file in $stringsdata; do args+=(--stringsdata "$file"); done
xcrun xcstringstool sync Glimt/Localizable.xcstrings $args
python3 - <<'PY'
import json, pathlib
catalog_path = pathlib.Path("Glimt/Localizable.xcstrings")
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
live = {key: entry for key, entry in catalog["strings"].items() if entry.get("extractionState") != "stale"}
for path in sorted(pathlib.Path("Localization").glob("*.json")):
    language = path.stem
    translations = json.loads(path.read_text(encoding="utf-8"))
    missing = [key for key in live if key not in translations]
    for key, entry in live.items():
        if key in translations:
            entry.setdefault("localizations", {})[language] = {"stringUnit": {"state": "translated", "value": translations[key]}}
    print(f"{language}: {len(live) - len(missing)} translated, {len(missing)} missing")
    for key in missing:
        print(f"  missing: {key!r}")
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
PY
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/build/DerivedData.noindex/Build/Products/Debug/Glimt.app" 2>/dev/null || true
