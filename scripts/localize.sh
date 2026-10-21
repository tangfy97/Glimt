#!/bin/zsh
# Refreshes Glimt/Localizable.xcstrings from the source and applies the Chinese translations in
# scripts/translations-zh-Hans.json. Prints any string still missing a translation.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Debug -derivedDataPath build/DerivedData.noindex build -quiet
stringsdata=(build/DerivedData.noindex/Build/Intermediates.noindex/Glimt.build/Debug/Glimt.build/Objects-normal/*/*.stringsdata)
args=()
for file in $stringsdata; do args+=(--stringsdata "$file"); done
xcrun xcstringstool sync Glimt/Localizable.xcstrings $args
python3 - <<'EOF'
import json
catalog_path = "Glimt/Localizable.xcstrings"
catalog = json.load(open(catalog_path, encoding="utf-8"))
translations = json.load(open("scripts/translations-zh-Hans.json", encoding="utf-8"))
missing = []
for key, entry in catalog["strings"].items():
    if entry.get("extractionState") == "stale":
        continue
    value = translations.get(key)
    if value is None:
        missing.append(key)
        continue
    entry.setdefault("localizations", {})["zh-Hans"] = {"stringUnit": {"state": "translated", "value": value}}
json.dump(catalog, open(catalog_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(catalog['strings']) - len(missing)} translated, {len(missing)} missing")
for key in missing:
    print("  missing:", key)
EOF
