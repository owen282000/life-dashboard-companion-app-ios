#!/bin/sh
# Renders the App Store screenshots from panorama.html with headless Chrome. Run from the
# repository root, after scripts/store-screenshots.sh has filled raw/.
#
#   panorama-en.png    the whole row, 7920x2868
#   en-1.png to en-6.png  one panel each, 1320x2868 (6.9 inch iPhone), RGB without alpha
#   6.3/en-1.png to en-6.png  the same panels scaled to 1206x2622 (6.3 inch iPhone)
#   contact-sheet.png  the six panels side by side, scaled down, for review
#   header-5244x2950.png, header-3840x1646.png  the product page header, header.html
#   search-3840x2560.png  the search results asset, header.html in 3:2
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR=docs/brand/app-store
SRC="file://$PWD/$DIR/panorama.html"

shot() { # out width height url
  "$CHROME" --headless=new --screenshot="$1" --window-size="$2,$3" --hide-scrollbars \
    --force-device-scale-factor=1 --force-color-profile=srgb --virtual-time-budget=4000 --default-background-color=0C1714FF \
    "$4" 2>/dev/null
}

shot "$DIR/panorama-en.png" 7920 2868 "$SRC"
for n in 1 2 3 4 5 6; do
  shot "$DIR/en-$n.png" 1320 2868 "$SRC?panel=$n"
done
mkdir -p "$DIR/6.3"
for n in 1 2 3 4 5 6; do
  sips -s format png -z 2622 1206 "$DIR/en-$n.png" --out "$DIR/6.3/en-$n.png" >/dev/null
done
for size in 5244x2950 3840x1646; do
  shot "$DIR/header-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size"
done
shot "$DIR/search-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560"
shot "$DIR/contact-sheet.png" 2196 797 "file://$PWD/$DIR/contact-sheet.html"

# Tagged as sRGB, which is what Chrome rendered them in.
for f in "$DIR"/en-*.png "$DIR"/6.3/en-*.png "$DIR/panorama-en.png" "$DIR"/header-*.png "$DIR"/search-*.png; do
  sips --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$f" >/dev/null
done

# The App Store refuses screenshots with an alpha channel: every one must say "no".
sips -g pixelWidth -g pixelHeight -g hasAlpha -g profile "$DIR"/en-*.png "$DIR"/6.3/en-*.png "$DIR/panorama-en.png" \
  "$DIR"/header-*.png "$DIR"/search-*.png
