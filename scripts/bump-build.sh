#!/usr/bin/env bash
#
# Sets the build number (CURRENT_PROJECT_VERSION) of the app, the widget and the tests to one
# value, before an archive for TestFlight or the App Store.
#
#   scripts/bump-build.sh          the number of commits up to HEAD, which only grows on main
#   scripts/bump-build.sh 137.1    a number of your own, for a second upload of the same commit
#
# App Store Connect refuses a build number it already has for the same version, and a widget
# whose build number differs from the app's, so every configuration gets the same value. The
# change is meant for the archive only: restore the project file after the upload.
set -euo pipefail
cd "$(dirname "$0")/.."

project=LifeDashboardCompanion.xcodeproj/project.pbxproj

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "This is a shallow clone, so the commit count is too low. Run: git fetch --unshallow" >&2
    exit 1
fi

build="${1:-$(git rev-list --count HEAD)}"
if ! [[ "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Not a build number: $build. Use one to three whole numbers with dots, like 137 or 137.1" >&2
    exit 1
fi

perl -pi -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $build;/" "$project"

# Every configuration, by bundle identifier, so a mismatch shows before the archive does.
awk '
    /buildSettings = \{/ { version = ""; build = ""; id = "" }
    /MARKETING_VERSION = / { version = $3 }
    /CURRENT_PROJECT_VERSION = / { build = $3 }
    /PRODUCT_BUNDLE_IDENTIFIER = / { id = $3 }
    /^\t\t\t\};/ { if (id != "") print id, version, build }
' "$project" | tr -d ';' | sort -u | while read -r id version number; do
    printf '%-40s %s (%s)\n' "$id" "$version" "$number"
done

if [ "$(grep -oE 'CURRENT_PROJECT_VERSION = [^;]+;' "$project" | sort -u | wc -l | tr -d ' ')" != 1 ]; then
    echo "The configurations disagree on the build number." >&2
    exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no -- . ":(exclude)$project")" ]; then
    echo "Warning: uncommitted changes besides the project file, so this build is not commit $(git rev-parse --short HEAD) alone." >&2
fi
echo "Build $build is commit $(git rev-parse --short HEAD). Archive now, then: git checkout -- $project"
