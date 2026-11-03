#!/bin/sh
# Renders the App Store screenshots from panorama.html with headless Chrome. Run from the
# repository root, after scripts/store-screenshots.sh has filled raw/ and raw/<lang>/.
# measure.swift first finds the rows the panels crop, per language (rects.js).
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
# Only what is uploaded or reviewed goes into git: the 6.9 inch panels, the contact sheets, the
# header and search images and the raw captures. The panoramas (about 10 MB each) and the 6.3
# inch panels are made here for a look and stay local (.gitignore); App Store Connect scales the
# 6.9 inch panels down for smaller iPhones itself. With oxipng installed (brew install oxipng),
# every new or changed PNG that git keeps is recompressed without loss and without changing its
# colour type.
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR=docs/brand/app-store
SRC="file://$PWD/$DIR/panorama.html"
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

shot() { # out width height url
  "$CHROME" --headless=new --screenshot="$1" --window-size="$2,$3" --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --force-color-profile=srgb --virtual-time-budget=4000 --default-background-color=0A0F0DFF \
    "$4" 2>/dev/null
}

WORK=build/store-render
mkdir -p "$WORK"
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
    shot "$DIR/header-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size"
    for lang in nl de; do
      shot "$DIR/header-$lang-$size.png" "${size%x*}" "${size#*x}" "file://$PWD/$DIR/header.html?size=$size&lang=$lang"
    done
  done
  shot "$DIR/search-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560"
  for lang in nl de; do
    shot "$DIR/search-$lang-3840x2560.png" 3840 2560 "file://$PWD/$DIR/header.html?size=3840x2560&lang=$lang"
  done
  for f in "$DIR"/header-*.png "$DIR"/search-*.png; do
    sips --embedProfile "$SRGB" "$f" >/dev/null
  done
  exit 0
fi

swift "$DIR/measure.swift"
[ $# -gt 0 ] || set -- en nl de fr es it pt-BR ja ar hi zh-Hans
for lang in "$@"; do
  if [ "$lang" = en ]; then sheet=contact-sheet.png; else sheet=contact-sheet-$lang.png; fi
  shot "$DIR/panorama-$lang.png" 7920 2868 "$SRC?lang=$lang"
  for n in 1 2 3 4 5 6; do
    panel "$DIR/$lang-$n.png" "$DIR/6.3" "$SRC?lang=$lang&panel=$n"
  done
  case "$lang" in
    en|nl|de)
      mkdir -p "$DIR/variant-a"
      panel "$DIR/variant-a/$lang-1.png" "$DIR/variant-a/6.3" "$SRC?lang=$lang&panel=1&variant=a"
      ;;
  esac
  shot "$DIR/$sheet" 2196 797 "file://$PWD/$DIR/contact-sheet.html?lang=$lang"
done

# Tagged as sRGB, which is what Chrome rendered them in.
for f in "$DIR"/*-[1-6].png "$DIR"/6.3/*-[1-6].png "$DIR"/variant-a/*.png "$DIR"/variant-a/6.3/*.png; do
  sips --embedProfile "$SRGB" "$f" >/dev/null
done

# Smaller files in git, the same pixels: lossless, RGB stays RGB, and the sRGB profile stays.
# Only files that are new or differ from git, so an unchanged render never shows as a change.
if command -v oxipng >/dev/null; then
  for f in "$DIR"/*-[1-6].png "$DIR"/contact-sheet*.png "$DIR"/variant-a/*.png "$DIR"/raw/*.png "$DIR"/raw/*/*.png; do
    if ! git ls-files --error-unmatch "$f" >/dev/null 2>&1 || ! git diff --quiet HEAD -- "$f"; then
      oxipng -q -o 4 --nx --strip safe "$f"
    fi
  done
else
  echo "oxipng not found: the PNGs stay as Chrome wrote them (brew install oxipng)" >&2
fi

# The App Store refuses screenshots with an alpha channel: every one must say "no".
sips -g pixelWidth -g pixelHeight -g hasAlpha "$DIR"/*-[1-6].png "$DIR"/6.3/*-[1-6].png "$DIR"/variant-a/*.png "$DIR"/variant-a/6.3/*.png \
  | grep -E 'pixel|hasAlpha' | paste - - - | sort | uniq -c
