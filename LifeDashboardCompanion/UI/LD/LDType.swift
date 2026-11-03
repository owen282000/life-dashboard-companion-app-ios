import SwiftUI

/// The PostScript names of the bundled fonts (Fonts/, registered in Info.plist under UIAppFonts).
enum LDFontName {
    static let regular = "SpaceGrotesk-Regular"
    static let medium = "SpaceGrotesk-Medium"
    static let bold = "SpaceGrotesk-Bold"
    static let monoRegular = "SpaceMono-Regular"
    static let monoBold = "SpaceMono-Bold"

    static let all = [regular, medium, bold, monoRegular, monoBold]
}

/// Fonts that scale with Dynamic Type. The size is the one on the boards at the default text size.
enum LDType {
    enum Weight {
        case regular, medium, bold

        var fontName: String {
            switch self {
            case .regular: return LDFontName.regular
            case .medium: return LDFontName.medium
            case .bold: return LDFontName.bold
            }
        }
    }

    /// Space Grotesk at any size, for what the named styles below do not cover.
    static func sans(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.fontName, size: size, relativeTo: style)
    }

    /// Space Mono for codes, times and technical values.
    static func mono(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .footnote) -> Font {
        .custom(bold ? LDFontName.monoBold : LDFontName.monoRegular, size: size, relativeTo: style)
    }

    static let heading = sans(30, .bold, relativeTo: .largeTitle)
    static let sectionLabel = sans(14, .medium, relativeTo: .subheadline)
    static let note = sans(14, relativeTo: .subheadline)
    static let noteSmall = sans(13, relativeTo: .footnote)
    static let row = sans(15, .medium, relativeTo: .subheadline)
    static let rowSubtitle = sans(13, relativeTo: .footnote)
    static let value = sans(14, relativeTo: .subheadline)
    static let tileTitle = sans(16, .bold, relativeTo: .callout)
    static let destination = sans(16, .medium, relativeTo: .callout)
    static let destinationStatus = sans(15, relativeTo: .subheadline)
    static let monoField = mono(14, relativeTo: .subheadline)
    static let monoValue = mono(12.5, relativeTo: .footnote)

    /// Extra space between lines so a font's own line height reaches the board's. Space Grotesk's
    /// natural line height is 1.276 times its size, so anything tighter than that cannot be reached.
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - size * 1.276)
    }
}
