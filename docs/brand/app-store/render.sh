#!/bin/sh
# Renders the App Store screenshots from panorama.html with headless Chrome into store-assets/,
# which is not in git. Run from the repository root, after scripts/store-screenshots.sh has filled
# store-assets/raw/ and store-assets/raw/<lang>/. measure.swift first finds the rows the panels
# crop, per language (rects.js).
#
#   docs/brand/app-store/render.sh               every language
#   docs/brand/app-store/render.sh nl de         only these
#   docs/brand/app-store/render.sh header        the header and search images instead
#
#   panorama-en.png    the whole row, 7920x2868
#   en-1.png to en-6.png  one panel each, 1320x2868 (6.9 inch iPhone), RGB without alpha
#   6.3/en-1.png to en-6.png  the same panels scaled to 1206x2622 (6.3 inch iPhone)
#   contact-sheet.png  the six panels side by side, scaled down, for review; other languages
#     contact-sheet-<lang>.png
#   variant-a/en-1.png, 6.3/en-1.png  the alternative first screenshot for the Product Page
#     Optimization test, in en, nl and de
#   header-5244x2950.png, header-3840x1646.png  the product page header, header.html
#   search-3840x2560.png  the search results asset, header.html in 3:2
#   header-nl-*.png, header-de-*.png, search-nl-*.png, search-de-*.png  the same in Dutch and German
#
# All of them land in store-assets/, with the same names. Only the sources are in git. App Store
# Connect scales the 6.9 inch panels down for smaller iPhones itself; the panoramas and the 6.3
# inch panels are for a look.
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR=docs/brand/app-store
OUT=store-assets
SRC="file://$PWD/$DIR/panorama.html"
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

shot() { # out width height url
  "$CHROME" --headless=new --screenshot="$1" --window-size="$2,$3" --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --force-color-profile=srgb --virtual-time-budget=4000 --default-background-color=0A0F0DFF \
    "$4" 2>/dev/null
}

WORK=build/store-render
mkdir -p "$WORK" "$OUT"
cat > "$WORK/flatten.swift" <<'SWIFT'
import AppKit
let path = CommandLine.arguments[1]
let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!.cgImage!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
SWIFT
swiftc -O -o "$WORK/flatten" "$WORK/flatten.swift" 2>/dev/null
finish() { "$WORK/flatten" "$1"; }

panel() { # out dir6.3 url
  shot "$1" 1320 2868 "$3"
  finish "$1"
  mkdir -p "$2"
  sips -s format png -z 2622 1206 "$1" --out "$2/$(basename "$1")" >/dev/null
  finish "$2/$(basename "$1")"
}

if [ "${1:-}" = header ]; then
  for size in 5244x2950 3840x1646; do
    shot "$OUT/header-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size"
    for lang in nl de; do
      shot "$OUT/header-$lang-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size&lang=$lang"
    done
  done
  shot "$OUT/search-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560"
  for lang in nl de; do
    shot "$OUT/search-$lang-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560&lang=$lang"
  done
  for f in "$OUT"/header-*.png "$OUT"/search-*.png; do
    sips --embedProfile "$SRGB" "$f" >/dev/null
  done
  exit 0
fi

swift "$DIR/measure.swift"
[ $# -gt 0 ] || set -- en nl de fr es it pt-BR ja ar hi zh-Hans
for lang in "$@"; do
  if [ "$lang" = en ]; then sheet=contact-sheet.png; else sheet=contact-sheet-$lang.png; fi
  shot "$OUT/panorama-$lang.png" 7920 2868 "$SRC?lang=$lang"
  for n in 1 2 3 4 5 6; do
    panel "$OUT/$lang-$n.png" "$OUT/6.3" "$SRC?lang=$lang&panel=$n"
  done
  case "$lang" in
    en|nl|de)
      mkdir -p "$OUT/variant-a"
      panel "$OUT/variant-a/$lang-1.png" "$OUT/variant-a/6.3" "$SRC?lang=$lang&panel=1&variant=a"
      ;;
  esac
  shot "$OUT/$sheet" 2196 797 "file://$PWD/$DIR/contact-sheet.html?lang=$lang"
done

# Tagged as sRGB, which is what Chrome rendered them in.
for f in "$OUT"/*-[1-6].png "$OUT"/6.3/*-[1-6].png "$OUT"/variant-a/*.png "$OUT"/variant-a/6.3/*.png; do
  sips --embedProfile "$SRGB" "$f" >/dev/null
done

# The App Store refuses screenshots with an alpha channel: every one must say "no".
sips -g pixelWidth -g pixelHeight -g hasAlpha "$OUT"/*-[1-6].png "$OUT"/6.3/*-[1-6].png "$OUT"/variant-a/*.png "$OUT"/variant-a/6.3/*.png \
  | grep -E 'pixel|hasAlpha' | paste - - - | sort | uniq -c
