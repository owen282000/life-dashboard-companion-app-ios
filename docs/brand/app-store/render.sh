#!/bin/sh
# Renders the App Store screenshots from panorama.html with headless Chrome. Run from the
# repository root, after scripts/store-screenshots.sh has filled raw/ (and raw/nl/, raw/de/
# with LANG_CODE=nl and LANG_CODE=de).
#
#   panorama-en.png    the whole row, 7920x2868
#   en-1.png to en-6.png  one panel each, 1320x2868 (6.9 inch iPhone), RGB without alpha
#   6.3/en-1.png to en-6.png  the same panels scaled to 1206x2622 (6.3 inch iPhone)
#   contact-sheet.png  the six panels side by side, scaled down, for review
#   the same in Dutch and German: panorama-nl.png, nl-1.png, 6.3/nl-1.png,
#     contact-sheet-nl.png, and de in place of nl
#   header-5244x2950.png, header-3840x1646.png  the product page header, header.html
#   search-3840x2560.png  the search results asset, header.html in 3:2
#   header-nl-*.png, header-de-*.png, search-nl-*.png, search-de-*.png  the same in Dutch and German
#
# Only what is uploaded or reviewed goes into git: the 6.9 inch panels, the contact sheets, the
# header and search images and the raw captures. The panoramas (about 10 MB each) and the 6.3
# inch panels are made here for a look and stay local (.gitignore); App Store Connect scales the
# 6.9 inch panels down for smaller iPhones itself. With oxipng installed (brew install oxipng),
# every new or changed PNG that git keeps is recompressed without loss and without changing its
# colour type.
# Commit only files whose source changed: a rerun of an unchanged page gives the same panels,
# but Chrome can render the header and search images a few bytes differently.
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR=docs/brand/app-store
SRC="file://$PWD/$DIR/panorama.html"

shot() { # out width height url
  "$CHROME" --headless=new --screenshot="$1" --window-size="$2,$3" --hide-scrollbars \
    --force-device-scale-factor=1 --force-color-profile=srgb --virtual-time-budget=4000 --default-background-color=0C1714FF \
    "$4" 2>/dev/null
}

mkdir -p "$DIR/6.3"
for lang in en nl de; do
  # English is the page without a query, as before; the others add lang=.
  if [ "$lang" = en ]; then q="?"; sheet=contact-sheet.png; else q="?lang=$lang&"; sheet=contact-sheet-$lang.png; fi
  shot "$DIR/panorama-$lang.png" 7920 2868 "$SRC${q%[?&]}"
  for n in 1 2 3 4 5 6; do
    shot "$DIR/$lang-$n.png" 1320 2868 "$SRC${q}panel=$n"
  done
  for n in 1 2 3 4 5 6; do
    sips -s format png -z 2622 1206 "$DIR/$lang-$n.png" --out "$DIR/6.3/$lang-$n.png" >/dev/null
  done
  shot "$DIR/$sheet" 2196 797 "file://$PWD/$DIR/contact-sheet.html${q%[?&]}"
done
for size in 5244x2950 3840x1646; do
  shot "$DIR/header-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size"
  for lang in nl de; do
    shot "$DIR/header-$lang-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size&lang=$lang"
  done
done
shot "$DIR/search-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560"
for lang in nl de; do
  shot "$DIR/search-$lang-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560&lang=$lang"
done

# Tagged as sRGB, which is what Chrome rendered them in.
for f in "$DIR"/??-[1-6].png "$DIR"/6.3/??-[1-6].png "$DIR"/panorama-??.png "$DIR"/header-*.png "$DIR"/search-*.png; do
  sips --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$f" >/dev/null
done

# Smaller files in git, the same pixels: lossless, RGB stays RGB, and the sRGB profile stays.
# Only files that are new or differ from git: an unchanged render keeps the bytes git already
# has, so it never shows up as a change (and a recompressed file is a whole new blob in git).
if command -v oxipng >/dev/null; then
  for f in "$DIR"/??-[1-6].png "$DIR"/contact-sheet*.png "$DIR"/header-*.png "$DIR"/search-*.png \
    "$DIR"/raw/*.png "$DIR"/raw/*/*.png; do
    if ! git ls-files --error-unmatch "$f" >/dev/null 2>&1 || ! git diff --quiet HEAD -- "$f"; then
      oxipng -q -o 4 --nx --strip safe "$f"
    fi
  done
else
  echo "oxipng not found: the PNGs stay as Chrome wrote them (brew install oxipng)" >&2
fi

# The App Store refuses screenshots with an alpha channel: every one must say "no".
sips -g pixelWidth -g pixelHeight -g hasAlpha -g profile "$DIR"/??-[1-6].png "$DIR"/6.3/??-[1-6].png "$DIR"/panorama-??.png \
  "$DIR"/header-*.png "$DIR"/search-*.png
