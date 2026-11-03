// Finds the rows and cards panorama.html crops in the captures of store-assets/raw/ and writes
// them to rects.js. A heading that wraps moves everything under it, per language and per screen, and
// Arabic mirrors. Run by render.sh from the repository root: swift docs/brand/app-store/measure.swift
import AppKit

let dir = "docs/brand/app-store"
let captures = "store-assets/raw"
let languages = ["en", "nl", "de", "fr", "es", "it", "pt-BR", "ja", "ar", "hi", "zh-Hans"]

struct Image {
    let width: Int, height: Int, pixels: [UInt8]
    init?(_ path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        width = source.width; height = source.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
    func isAccent(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = rgb(x, y)
        return g > 150 && r < 100 && b > 90 && b < 160
    }
    /// A card: a shade lighter than both the ground and a sheet.
    func isTile(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = rgb(x, y)
        return r >= 17 && r <= 27 && g >= 25 && g <= 35 && b >= 21 && b <= 31
    }
    /// Vertical stretches of a card in column x, from y on, with the dividers inside them.
    func cards(x: Int, from: Int = 0) -> [(top: Int, bottom: Int, dividers: [Int])] {
        var result: [(top: Int, bottom: Int, dividers: [Int])] = []
        var top: Int?, last = 0, dividers: [Int] = []
        for y in from..<height {
            guard isTile(x, y) else { continue }
            if let start = top, y - last > 6 {
                result.append((start, last, dividers))
                top = y; dividers = []
            } else if let _ = top, y - last > 1 {
                dividers.append(last + 1)
            }
            if top == nil { top = y }
            last = y
        }
        if let start = top { result.append((start, last, dividers)) }
        return result.filter { $0.bottom - $0.top > 60 }
    }
    /// The first stretch of accent in column x with at least minHeight pixels, from y on.
    func accentRun(x: Int, from: Int, minHeight: Int) -> (top: Int, bottom: Int)? {
        var y = from
        while y < height {
            if isAccent(x, y) {
                var end = y
                while end + 1 < height, isAccent(x, end + 1) { end += 1 }
                if end - y + 1 >= minHeight { return (y, end) }
                y = end
            }
            y += 1
        }
        return nil
    }
    /// The hairlines that run across the whole width, in the margin left of the rows.
    func hairlines(from: Int) -> [Int] {
        let ground = rgb(20, from)
        var lines: [Int] = []
        for y in from..<(height - 1) {
            let (r, g, b) = rgb(20, y)
            if abs(r - ground.0) + abs(g - ground.1) + abs(b - ground.2) > 12, lines.last.map({ y - $0 > 4 }) ?? true {
                lines.append(y)
            }
        }
        return lines
    }
}

var out = "// Written by measure.swift from the captures in store-assets/raw/: [x, y, w, h] in capture pixels.\nconst MEASURED = {\n"
for language in languages {
    let raw = language == "en" ? captures : "\(captures)/\(language)"
    guard let home = Image("\(raw)/health.png"), let scan = Image("\(raw)/setup-destination.png"),
          let hook = Image("\(raw)/webhook.png"), let delivery = Image("\(raw)/delivery.png"),
          let what = Image("\(raw)/what.png"), let logs = Image("\(raw)/logs.png"),
          let about = Image("\(raw)/about.png") else { continue }
    let rtl = language == "ar"
    let edge = rtl ? 1314 : 6       // where the heartbeat line enters the screen
    let inCard = rtl ? 1250 : 70    // inside a card, left of its text (right of it in Arabic)

    let homeLine = home.accentRun(x: edge, from: 300, minHeight: 6)!
    let dests = [30, (homeLine.top + homeLine.bottom) / 2 + 141, 1260, 400]

    let button = scan.accentRun(x: rtl ? 1200 : 120, from: 400, minHeight: 100)!
    let scanRect = [42, button.top, 1236, button.bottom - button.top + 1]

    let signingCard = hook.cards(x: inCard, from: 600)[1]
    let afterSigning = hook.cards(x: inCard, from: signingCard.bottom + 10)[0]
    let signing = [30, signingCard.top - 70, 1260, afterSigning.top - 100 - (signingCard.top - 70)]

    let payloadTop = delivery.cards(x: inCard, from: 500).last!.top
    // Up to the last gap between two lines of the JSON, so no line is cut through.
    var payloadEnd = payloadTop + min(800, 2410 - payloadTop)
    while (60..<1260).contains(where: { x in let (r, g, b) = delivery.rgb(x, payloadEnd); return max(r, g, b) > 110 }) { payloadEnd -= 1 }
    let payload = [44, payloadTop, 1232, payloadEnd - payloadTop]

    // The pill: in its left padding for the height, then along a row above its label for the
    // width, plus what the round ends take off in both.
    let pillColumn = rtl ? 1232 : 88
    let pillRun = what.accentRun(x: pillColumn, from: 500, minHeight: 60)!
    let pillRow = pillRun.top + 22
    var left = pillColumn, right = pillColumn
    while left > 0, what.isAccent(left - 1, pillRow) { left -= 1 }
    while right < 1319, what.isAccent(right + 1, pillRow) { right += 1 }
    let essentials = [left - 8, pillRun.top - 12, right - left + 17, pillRun.bottom - pillRun.top + 25]

    // How it goes out, the card under the categories: Data resolution and Send history.
    let goesOut = what.cards(x: inCard, from: pillRun.bottom)[1]
    let rowsEnd = goesOut.dividers.filter { $0 > goesOut.top + 60 }.dropFirst().first ?? goesOut.top + 300
    let rows = [44, goesOut.top - 2, 1232, rowsEnd - goesOut.top + 2]

    let lines = logs.hairlines(from: 600)
    let logRows = [0, lines[1], 1320, lines[4] - lines[1]]

    let aboutLine = about.accentRun(x: edge, from: 400, minHeight: 6)!
    let splitY = (aboutLine.top + aboutLine.bottom) / 2
    let tiles = about.cards(x: inCard, from: splitY + 300)
    let tile = tiles.last!
    // In its left padding the round corner takes about 11 pixels off the top and the bottom.
    let leftTile = [43, tile.top - 11, 604, tile.bottom - tile.top + 23]
    let rightTile = [673, tile.top - 11, 604, tile.bottom - tile.top + 23]

    func js(_ rect: [Int]) -> String { "[\(rect.map(String.init).joined(separator: ", "))]" }
    out += "  \"\(language)\": { dests: \(js(dests)), scan: \(js(scanRect)), signing: \(js(signing)), payload: \(js(payload)), "
    out += "essentials: \(js(essentials)), rows: \(js(rows)), logrows: \(js(logRows)), splitY: \(splitY), "
    out += "split: \(js([0, splitY - 260, 1320, 560])), privacy: \(js(rtl ? rightTile : leftTile)), source: \(js(rtl ? leftTile : rightTile)) },\n"
}
out += "};\n"
try out.write(toFile: "\(dir)/rects.js", atomically: true, encoding: .utf8)
