// Writes the layers of the app icon, LifeDashboardCompanion/AppIcon.icon/Assets/*.svg, from the
// heartbeat mark in app-icon.html: the same points, doubled to Icon Composer's 1024 pt canvas.
// From the repository root:
//
//   swift docs/brand/app-icon-layers.swift
//
// Each layer is a filled outline, not a stroke. Liquid Glass shades a layer by its path, and an open
// stroked path counts as closed there: the pulse got a line from its end back to its start and each
// arc a line across its chord. CoreGraphics strokes the mark and joins it into one closed outline.
import CoreGraphics
import Foundation

let green = "#30B77E"
let canvas = 1024

func number(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
}

func pathData(_ path: CGPath) -> String {
    var parts: [String] = []
    path.applyWithBlock { element in
        let points = element.pointee.points
        func pair(_ index: Int) -> String { "\(number(points[index].x)) \(number(points[index].y))" }
        switch element.pointee.type {
        case .moveToPoint: parts.append("M" + pair(0))
        case .addLineToPoint: parts.append("L" + pair(0))
        case .addQuadCurveToPoint: parts.append("Q" + pair(0) + " " + pair(1))
        case .addCurveToPoint: parts.append("C" + pair(0) + " " + pair(1) + " " + pair(2))
        case .closeSubpath: parts.append("Z")
        @unknown default: break
        }
    }
    return parts.joined(separator: " ")
}

func outline(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized(using: .winding)
}

/// An arc from (chordX, top) to (chordX, bottom) that bulges to the right with radius r, like the
/// SVG arc `M chordX top A r r 0 0 1 chordX bottom`.
func arc(chordX: CGFloat, top: CGFloat, bottom: CGFloat, radius: CGFloat) -> CGPath {
    let half = (bottom - top) / 2
    let centre = CGPoint(x: chordX - (radius * radius - half * half).squareRoot(), y: top + half)
    let angle = asin(half / radius)
    let path = CGMutablePath()
    path.addArc(center: centre, radius: radius, startAngle: -angle, endAngle: angle, clockwise: false)
    return path
}

// app-icon.html: M64 256 L158 256 L186 176 L232 340 L264 232 L290 256 L330 256, stroke 26, dot r 20.
let pulse = CGMutablePath()
pulse.move(to: CGPoint(x: 128, y: 512))
for (px, py) in [(316, 512), (372, 352), (464, 680), (528, 464), (580, 512), (660, 512)] {
    pulse.addLine(to: CGPoint(x: px, y: py))
}
let dot = CGPath(ellipseIn: CGRect(x: 620, y: 472, width: 80, height: 80), transform: nil)

let layers: [(name: String, shape: CGPath)] = [
    ("pulse", outline(pulse, width: 52).union(dot, using: .winding)),
    // M376 216 A 60 60 0 0 1 376 296 and M410 186 A 105 105 0 0 1 410 326, stroke 20.
    ("arc-inner", outline(arc(chordX: 752, top: 432, bottom: 592, radius: 120), width: 40)),
    ("arc-outer", outline(arc(chordX: 820, top: 372, bottom: 652, radius: 210), width: 40))
]

let folder = URL(fileURLWithPath: "LifeDashboardCompanion/AppIcon.icon/Assets", isDirectory: true)
for layer in layers {
    let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
          <path fill="\(green)" d="\(pathData(layer.shape))"/>
        </svg>

        """
    let file = folder.appendingPathComponent(layer.name + ".svg")
    try svg.write(to: file, atomically: true, encoding: .utf8)
    print(file.path)
}
