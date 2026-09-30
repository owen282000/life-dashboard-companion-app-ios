import SwiftUI
import UIKit

/// One colour of the Android app's palette (its ui/theme/Color.kt), with the value per
/// appearance. Kept as numbers so a test can measure every pair the screens draw.
struct BrandTone: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32
    let lightHigh: UInt32
    let darkHigh: UInt32

    init(_ value: UInt32) {
        self.init(light: value, dark: value)
    }

    init(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightHigh = lightHigh ?? light
        self.darkHigh = darkHigh ?? dark
    }

    func value(dark isDark: Bool, highContrast: Bool) -> UInt32 {
        switch (isDark, highContrast) {
        case (false, false): return light
        case (true, false): return dark
        case (false, true): return lightHigh
        case (true, true): return darkHigh
        }
    }

    var uiColor: UIColor {
        let tone = self
        return UIColor { traits in
            UIColor(rgb: tone.value(
                dark: traits.userInterfaceStyle == .dark,
                highContrast: traits.accessibilityContrast == .high
            ))
        }
    }

    // Fills keep the Android colour as it is. Text and glyphs on a light surface use the darker
    // ink of the same colour: every Android accent fails 4.5:1 as text on white, brand green
    // at 2.56:1. Text on a green or blue fill is the dark ink, Android's own OnPrimary rule.
    static let green = BrandTone(0x30B77E)
    static let ink = BrandTone(light: 0x207953, dark: 0x30B77E, lightHigh: 0x1E714E, darkHigh: 0x4CC994)
    static let onGreen = BrandTone(light: 0x14181C, dark: 0x14181C, lightHigh: 0x000000, darkHigh: 0x000000)
    static let logs = BrandTone(0x2F80ED)
    static let logsInk = BrandTone(light: 0x1D64C8, dark: 0x60A5FA, lightHigh: 0x1D4ED8, darkHigh: 0x93C5FD)
    static let success = BrandTone(0x22C55E)
    static let successInk = BrandTone(light: 0x166534, dark: 0x22C55E, lightHigh: 0x14532D, darkHigh: 0x4ADE80)
    static let error = BrandTone(0xEF4444)
    static let errorInk = BrandTone(light: 0xB91C1C, dark: 0xF87171, lightHigh: 0x991B1B, darkHigh: 0xFCA5A5)
    static let warning = BrandTone(0xF59E0B)
    static let warningInk = BrandTone(light: 0x92400E, dark: 0xFBBF24, lightHigh: 0x78350F, darkHigh: 0xFCD34D)
    static let successContainer = BrandTone(light: 0xDCFCE7, dark: 0x14532D)
    static let onSuccessContainer = BrandTone(light: 0x166534, dark: 0xBBF7D0)
    static let errorContainer = BrandTone(light: 0xFEE2E2, dark: 0x7F1D1D)
    static let onErrorContainer = BrandTone(light: 0x991B1B, dark: 0xFECACA)
    static let warningContainer = BrandTone(light: 0xFEF3C7, dark: 0x78350F)
    static let onWarningContainer = BrandTone(light: 0x92400E, dark: 0xFDE68A)
    static let logsContainer = BrandTone(light: 0xDBEAFE, dark: 0x1E3A8A)
    static let onLogsContainer = BrandTone(light: 0x1E3A8A, dark: 0xBFDBFE)
    // The dark brand ground of the icon and the About hero, the same in both appearances.
    static let groundLight = BrandTone(0x171D21)
    static let ground = BrandTone(0x14181C)
    static let groundDeep = BrandTone(0x101C1C)
    static let heroSubtitle = BrandTone(0xB9C2C6)
    static let nerdStar = BrandTone(0xF9A825)
}

/// The palette as SwiftUI colours. Compiled into the app and the widget.
enum Brand {
    static let green = Color(BrandTone.green)
    static let ink = Color(BrandTone.ink)
    static let onGreen = Color(BrandTone.onGreen)
    static let logs = Color(BrandTone.logs)
    static let logsInk = Color(BrandTone.logsInk)
    static let success = Color(BrandTone.success)
    static let successInk = Color(BrandTone.successInk)
    static let error = Color(BrandTone.error)
    static let errorInk = Color(BrandTone.errorInk)
    static let warning = Color(BrandTone.warning)
    static let warningInk = Color(BrandTone.warningInk)
    static let ground = [Color(BrandTone.groundLight), Color(BrandTone.ground), Color(BrandTone.groundDeep)]
    static let heroSubtitle = Color(BrandTone.heroSubtitle)
    static let nerdStar = Color(BrandTone.nerdStar)

    /// Android's card, tile and hero corners.
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 11
    static let actionTileRadius: CGFloat = 14
    static let heroRadius: CGFloat = 28
}

extension Color {
    init(_ tone: BrandTone) {
        self.init(uiColor: tone.uiColor)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - The mark

/// The heartbeat that broadcasts: a pulse, its end dot and two arcs, from the brand's
/// docs/brand/icon.html (a 512 box). Drawn in code so it is sharp at any size and needs no image.
enum BrandMarkPart: CaseIterable {
    case pulse, dot, innerArc, outerArc

    /// The part of the 512 box the mark covers, strokes included, so the mark fills its frame.
    static let viewBox = CGRect(x: 40, y: 150, width: 432, height: 216)

    var lineWidth: CGFloat { self == .pulse ? 26 : 20 }

    var opacity: Double {
        switch self {
        case .pulse, .dot: return 1
        case .innerArc: return 0.85
        case .outerArc: return 0.5
        }
    }

    /// The path in icon.html's own coordinates.
    var sourcePath: Path {
        var path = Path()
        switch self {
        case .pulse:
            let points: [(CGFloat, CGFloat)] = [(64, 256), (158, 256), (186, 176), (232, 340), (264, 232), (290, 256), (330, 256)]
            path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        case .dot:
            path.addEllipse(in: CGRect(x: 310, y: 236, width: 40, height: 40))
        case .innerArc:
            path = BrandMarkPart.arc(from: CGPoint(x: 376, y: 216), to: CGPoint(x: 376, y: 296), radius: 60)
        case .outerArc:
            path = BrandMarkPart.arc(from: CGPoint(x: 410, y: 186), to: CGPoint(x: 410, y: 326), radius: 105)
        }
        return path
    }

    /// The path fitted into `rect`, keeping the mark's proportions.
    func path(in rect: CGRect) -> Path {
        sourcePath.applying(BrandMarkPart.transform(into: rect))
    }

    static func scale(for rect: CGRect) -> CGFloat {
        min(rect.width / viewBox.width, rect.height / viewBox.height)
    }

    static func transform(into rect: CGRect) -> CGAffineTransform {
        let scale = scale(for: rect)
        let offsetX = rect.midX - viewBox.midX * scale
        let offsetY = rect.midY - viewBox.midY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
    }

    /// An SVG arc (small, clockwise) between two points on a vertical chord, bulging right.
    private static func arc(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> Path {
        let halfChord = (end.y - start.y) / 2
        let centerX = start.x - sqrt(radius * radius - halfChord * halfChord)
        let center = CGPoint(x: centerX, y: (start.y + end.y) / 2)
        let startAngle = Angle(radians: atan2(start.y - center.y, start.x - center.x))
        let endAngle = Angle(radians: atan2(end.y - center.y, end.x - center.x))
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

/// The mark in brand green, scaled to its frame.
struct BrandMark: View {
    var color: Color = Brand.green
    var glow = false

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let scale = BrandMarkPart.scale(for: rect)
            ZStack {
                ForEach(BrandMarkPart.allCases, id: \.self) { part in
                    if part == .dot {
                        part.path(in: rect).fill(color)
                    } else {
                        part.path(in: rect)
                            .stroke(color, style: StrokeStyle(lineWidth: part.lineWidth * scale, lineCap: .round, lineJoin: .round))
                            .opacity(part.opacity)
                    }
                }
            }
            .shadow(color: glow ? color.opacity(0.55) : .clear, radius: 14 * scale)
        }
        .aspectRatio(BrandMarkPart.viewBox.width / BrandMarkPart.viewBox.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
