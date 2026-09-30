#!/usr/bin/env bash
#
# The translation loop, without opening Xcode. See docs/localization.md.
#
#   scripts/l10n.sh sync     puts every string the code uses into the String Catalogs, the way an
#                            Xcode build does, and lists what still needs Dutch and German
#   scripts/l10n.sh prune    removes the keys the code no longer uses (after their translation
#                            served as a starting point for the reworded English)
#   scripts/l10n.sh check    builds and fails on anything untranslated, as CI does
#   scripts/l10n.sh check --objroot build --symroot build
#                            checks an existing build instead (CI reuses its own)
#
set -euo pipefail
cd "$(dirname "$0")/.."

command="${1:-check}"
shift || true

catalogs=(
    LifeDashboardCompanion/Localizable.xcstrings
    LifeDashboardCompanion/InfoPlist.xcstrings
    LifeDashboardCompanion/AppShortcuts.xcstrings
    LifeDashboardWidget/Localizable.xcstrings
)

case "$command" in
sync)
    # The same engine as Xcode's own extraction: it adds new keys, marks unused ones stale and
    # keeps Xcode's key order, so an IDE build afterwards changes nothing.
    out="build/l10n-export"
    xcodebuild -exportLocalizations \
        -project LifeDashboardCompanion.xcodeproj \
        -localizationPath "$out/xcloc" \
        -exportLanguage nl -exportLanguage de \
        SYMROOT="$PWD/$out/sym" OBJROOT="$PWD/$out/obj" >/dev/null
    python3 - "${catalogs[@]}" <<'EOF'
import sys
sys.path.insert(0, "scripts/l10n")
import catalog

for path in sys.argv[1:]:
    for key, entry in catalog.load(path)["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            print(f"{path}: stale (reuse its translation, then prune): {key!r}")
            continue
        missing = [lang for lang in ("nl", "de") if lang not in entry.get("localizations", {})]
        if missing:
            print(f"{path}: needs {' and '.join(missing)}: {key!r}")
EOF
    ;;
prune)
    python3 - "${catalogs[@]}" <<'EOF'
import sys
sys.path.insert(0, "scripts/l10n")
import catalog

for path in sys.argv[1:]:
    data = catalog.load(path)
    stale = [k for k, v in data["strings"].items() if v.get("extractionState") == "stale"]
    for key in stale:
        del data["strings"][key]
        print(f"{path}: removed {key!r}")
    catalog.save(path, data)
EOF
    ;;
check)
    if [[ " $* " != *" --objroot "* ]]; then
        out="build/l10n"
        # Same flags as the CI build, into a folder of its own so an Xcode build is not disturbed.
        xcodebuild -quiet \
            -project LifeDashboardCompanion.xcodeproj \
            -target LifeDashboardCompanion \
            -sdk iphonesimulator \
            -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            SYMROOT="$PWD/$out" OBJROOT="$PWD/$out" \
            build
        set -- --objroot "$out" --symroot "$out" "$@"
    fi
    exec python3 scripts/l10n/check.py "$@"
    ;;
*)
    echo "usage: scripts/l10n.sh sync | prune | check [--objroot DIR --symroot DIR] [--github]" >&2
    exit 2
    ;;
esac
