import SwiftUI

/// The boards' heartbeat line in its 390 by 76 box. All of it is scaled by the width it gets.
private enum PulseGeometry {
    static let box = CGSize(width: 390, height: 76)
    static let lineWidth: CGFloat = 4

    static func line(flat: Bool) -> Path {
        // M0 42H136l11-26 17 52 15-38 7 12h40, or M0 42H226 when flat.
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 42))
        if flat {
            path.addLine(to: CGPoint(x: 226, y: 42))
        } else {
            for point in beat {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: 226, y: 42))
        }
        return path
    }

    /// The onboarding progress: the same beat, running on to the end of the box.
    static var progressLine: Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 42))
        for point in beat {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: 380, y: 42))
        return path
    }

    private static let beat = [
        CGPoint(x: 136, y: 42), CGPoint(x: 147, y: 16), CGPoint(x: 164, y: 68),
        CGPoint(x: 179, y: 30), CGPoint(x: 186, y: 42)
    ]

    static func dot(scale: CGFloat) -> Path {
        let radius = 7 * scale
        return Path(ellipseIn: CGRect(x: 232 - radius, y: 42 - radius, width: radius * 2, height: radius * 2))
    }

    /// M250 28a20 20 0 0 1 0 28: both ends known, so the centre follows from the radius.
    static var innerArc: Path { arc(start: 250, top: 28, bottom: 56, radius: 20) }
    /// M266 18a36 36 0 0 1 0 48.
    static var outerArc: Path { arc(start: 266, top: 18, bottom: 66, radius: 36) }

    private static func arc(start: CGFloat, top: CGFloat, bottom: CGFloat, radius: CGFloat) -> Path {
        let half = (bottom - top) / 2
        let center = CGPoint(x: start - (radius * radius - half * half).squareRoot(), y: top + half)
        let angle = Angle(radians: asin(Double(half / radius)))
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: -angle, endAngle: angle, clockwise: false)
        return path
    }
}

/// One part of the line, shown up to where `progress` has reached `window`. A Shape, so SwiftUI
/// interpolates `progress` frame by frame and the parts follow each other.
private struct PulsePart: Shape {
    enum Part {
        case line(flat: Bool), progressLine, dot, innerArc, outerArc
    }

    let part: Part
    let window: ClosedRange<Double>
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let span = window.upperBound - window.lowerBound
        let local = min(1, max(0, (progress - window.lowerBound) / span))
        guard local > 0 else { return Path() }

        let drawn: Path
        switch part {
        case .line(let flat):
            drawn = stroked(PulseGeometry.line(flat: flat).trimmedPath(from: 0, to: local))
        case .progressLine:
            drawn = stroked(PulseGeometry.progressLine.trimmedPath(from: 0, to: local))
        case .dot:
            drawn = PulseGeometry.dot(scale: local)
        case .innerArc:
            drawn = stroked(PulseGeometry.innerArc.trimmedPath(from: 0, to: local))
        case .outerArc:
            drawn = stroked(PulseGeometry.outerArc.trimmedPath(from: 0, to: local))
        }
        let scale = rect.width / PulseGeometry.box.width
        return drawn.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private func stroked(_ path: Path) -> Path {
        path.strokedPath(StrokeStyle(lineWidth: PulseGeometry.lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// The heartbeat line with its dot and two arcs. It runs from the left screen edge, so it sits
/// directly in an LDScreen without a margin. Draws in when it appears, off with Reduce Motion.
struct PulseLine: View {
    enum Variant {
        /// Everything is arriving.
        case normal
        /// A destination needs attention.
        case warning
        /// Nothing to send yet: no beat, in the dim colours.
        case flat

        var color: Color {
            switch self {
            case .normal: return LDTheme.accent
            case .warning: return LDTheme.warning
            case .flat: return LDTheme.flatLine
            }
        }

        var dimColor: Color {
            switch self {
            case .normal: return LDTheme.accentDim
            case .warning: return LDTheme.warningDim
            case .flat: return LDTheme.flatDim
            }
        }
    }

    var variant: Variant = .normal

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        let shown = reduceMotion ? 1 : progress
        ZStack {
            PulsePart(part: .line(flat: variant == .flat), window: 0...0.62, progress: shown).fill(variant.color)
            PulsePart(part: .dot, window: 0.6...0.72, progress: shown).fill(variant.color)
            PulsePart(part: .innerArc, window: 0.7...0.86, progress: shown).fill(variant.color)
            PulsePart(part: .outerArc, window: 0.84...1, progress: shown).fill(variant.dimColor)
        }
        .aspectRatio(PulseGeometry.box.width / PulseGeometry.box.height, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { progress = 1 }
        }
        .onDisappear { progress = 0 }
    }
}

/// The onboarding's progress: the beat in the dim colour, with the accent drawn over it up to this
/// step. It draws on from the previous step, also when each step builds its own PulseProgress.
struct PulseProgress: View {
    let step: Int
    let of: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double

    init(step: Int, of: Int) {
        self.step = step
        self.of = of
        _shown = State(initialValue: Self.fraction(step - 1, of: of))
    }

    private static func fraction(_ step: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(step) / Double(total)))
    }

    var body: some View {
        let target = Self.fraction(step, of: of)
        ZStack {
            PulsePart(part: .progressLine, window: 0...1, progress: 1).fill(LDTheme.flatDim)
            PulsePart(part: .progressLine, window: 0...1, progress: reduceMotion ? target : shown).fill(LDTheme.accent)
        }
        .aspectRatio(PulseGeometry.box.width / PulseGeometry.box.height, contentMode: .fit)
        // "Step N of 5" says it in words next to the line.
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { shown = target }
        }
        .onChange(of: step) { _, _ in
            withAnimation(.easeOut(duration: 0.6)) { shown = target }
        }
    }
}

/// A series as a thin line ending in a dot, drawn in on appear. Draws nothing without values;
/// one value is a dot on its own.
struct SparkLine: View {
    let values: [Double]
    var color: Color = LDTheme.accent
    var height: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        let shown = reduceMotion ? 1 : progress
        ZStack {
            SparkShape(values: values, part: .line, progress: shown).fill(color)
            SparkShape(values: values, part: .dot, progress: shown).fill(color)
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
        }
        .onDisappear { progress = 0 }
    }
}

private struct SparkShape: Shape {
    enum Part { case line, dot }

    let values: [Double]
    let part: Part
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 3
        guard let low = values.min(), let high = values.max() else { return Path() }
        let spread = high > low ? high - low : 1
        let width = rect.width - inset * 2
        let height = rect.height - inset * 2
        let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0
        let points = values.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + (values.count > 1 ? inset + step * CGFloat(index) : rect.width - inset),
                y: rect.minY + rect.height - inset - height * CGFloat((value - low) / spread)
            )
        }
        switch part {
        case .line:
            guard points.count > 1, progress > 0 else { return Path() }
            var line = Path()
            line.addLines(points)
            return line.trimmedPath(from: 0, to: min(1, progress))
                .strokedPath(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .dot:
            guard let last = points.last else { return Path() }
            let radius = 3 * min(1, max(0, (progress - 0.8) / 0.2))
            return Path(ellipseIn: CGRect(x: last.x - radius, y: last.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}
