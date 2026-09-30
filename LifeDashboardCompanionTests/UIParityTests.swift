import XCTest
import UIKit
@testable import LifeDashboardCompanion

/// The palette, the mark and the symbols the screens draw, measured instead of assumed.
final class UIParityTests: XCTestCase {

    // MARK: - Contrast

    private func luminance(_ rgb: UInt32) -> Double {
        let channels = [16, 8, 0].map { Double((rgb >> UInt32($0)) & 0xFF) / 255 }
        let linear = channels.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }

    /// `color` laid over `background` at `alpha`, as a tinted tile draws it.
    private func blend(_ color: UInt32, over background: UInt32, alpha: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let top = Double((color >> UInt32(shift)) & 0xFF)
            let bottom = Double((background >> UInt32(shift)) & 0xFF)
            return result | (UInt32((top * alpha + bottom * (1 - alpha)).rounded()) << UInt32(shift))
        }
    }

    // iOS grouped backgrounds: page and card, light and dark.
    private let lightSurfaces: [UInt32] = [0xFFFFFF, 0xF2F2F7]
    private let darkSurfaces: [UInt32] = [0x000000, 0x1C1C1E, 0x2C2C2E]

    private let textTones: [(String, BrandTone)] = [
        ("ink", .ink), ("logsInk", .logsInk), ("successInk", .successInk),
        ("errorInk", .errorInk), ("warningInk", .warningInk)
    ]

    func testTextTonesReadOnEverySurface() {
        for (name, tone) in textTones {
            for surface in lightSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(tone.light, surface), 4.5, "\(name) light on \(String(surface, radix: 16))")
                XCTAssertGreaterThanOrEqual(contrast(tone.lightHigh, surface), 4.5, "\(name) light, high contrast")
            }
            for surface in darkSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(tone.dark, surface), 4.5, "\(name) dark on \(String(surface, radix: 16))")
                XCTAssertGreaterThanOrEqual(contrast(tone.darkHigh, surface), 4.5, "\(name) dark, high contrast")
            }
        }
    }

    func testGlyphsReadOnTheirTintedTiles() {
        // An icon tile is the accent at 12% (light) or 18% (dark) behind a glyph in the ink.
        for (fill, ink) in [(BrandTone.green, BrandTone.ink), (.logs, .logsInk)] {
            for surface in lightSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(ink.light, blend(fill.light, over: surface, alpha: 0.12)), 3)
            }
            for surface in darkSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(ink.dark, blend(fill.dark, over: surface, alpha: 0.18)), 3)
            }
        }
    }

    func testTheBrandGreenIsNeverTextOnLightButCarriesDarkInk() {
        // The reason the ink exists: Android's green is 2.56:1 on white.
        XCTAssertLessThan(contrast(BrandTone.green.light, 0xFFFFFF), 3)
        // Text on the green fill and across the header gradient, in both appearances.
        for fill: UInt32 in [0x30B77E, 0x6ACBA2, 0x2F80ED] {
            XCTAssertGreaterThanOrEqual(contrast(BrandTone.onGreen.light, fill), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(BrandTone.onGreen.lightHigh, fill), 4.5)
        }
    }

    func testStatusPillsReadInBothAppearances() {
        let pairs: [(BrandTone, BrandTone)] = [
            (.onSuccessContainer, .successContainer), (.onErrorContainer, .errorContainer),
            (.onWarningContainer, .warningContainer), (.onLogsContainer, .logsContainer)
        ]
        for (text, container) in pairs {
            XCTAssertGreaterThanOrEqual(contrast(text.light, container.light), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(text.dark, container.dark), 4.5)
        }
    }

    func testTheHeroReadsOnTheBrandGround() {
        for ground in [BrandTone.groundLight, .ground, .groundDeep] {
            XCTAssertGreaterThanOrEqual(contrast(BrandTone.heroSubtitle.light, ground.light), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(BrandTone.green.light, blend(BrandTone.green.light, over: ground.light, alpha: 0.18)), 4.5)
        }
    }

    // MARK: - Accent colour

    /// The asset catalog's AccentColor tints every system control, so it must be the ink.
    func testAccentColorIsTheInkInEveryAppearance() throws {
        let bundle = Bundle(for: HealthKitManager.self)
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrastLevel in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(accessibilityContrast: contrastLevel)
                ])
                let accent = try XCTUnwrap(UIColor(named: "AccentColor", in: bundle, compatibleWith: traits))
                let expected = BrandTone.ink.value(dark: style == .dark, highContrast: contrastLevel == .high)
                XCTAssertEqual(rgb(of: accent.resolvedColor(with: traits)), expected, "\(style.rawValue) \(contrastLevel.rawValue)")
            }
        }
    }

    func testToneResolvesPerTrait() {
        let tone = BrandTone.ink
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(rgb(of: tone.uiColor.resolvedColor(with: dark)), tone.dark)
        XCTAssertEqual(rgb(of: tone.uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))), tone.light)
    }

    private func rgb(of color: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].reduce(UInt32(0)) { ($0 << 8) | UInt32(($1 * 255).rounded()) }
    }

    // MARK: - Mark and symbols

    func testEveryPartOfTheMarkLiesInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        for part in BrandMarkPart.allCases {
            let bounds = part.path(in: rect).boundingRect
            XCTAssertFalse(bounds.isEmpty, "\(part)")
            XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(bounds), "\(part) \(bounds)")
        }
        // The outer arc bulges right of its chord, as in icon.html.
        XCTAssertGreaterThan(BrandMarkPart.outerArc.sourcePath.boundingRect.maxX, 430)
    }

    func testEverySymbolTheScreensUseExists() {
        let symbols = HealthDataType.allCases.map(\.icon) + UIParityTests.screenSymbols
        for name in symbols {
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
    }

    static let screenSymbols = [
        "waveform.path.ecg.rectangle", "clock", "link", "house", "slider.horizontal.3", "bell",
        "eye", "dot.radiowaves.left.and.right", "clock.arrow.circlepath", "qrcode.viewfinder",
        "chevron.down", "xmark", "plus", "checkmark.circle.fill", "exclamationmark.triangle.fill",
        "exclamationmark.circle.fill", "info.circle.fill", "info.circle", "square.and.arrow.up",
        "trash", "heart.fill", "heart", "heart.slash", "tray.full"
    ]
}
