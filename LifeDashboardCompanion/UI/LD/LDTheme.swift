import SwiftUI

/// The A2b palette per appearance, as numbers like `BrandTone` itself. Dark is the designed look,
/// light the same product on a pale ground: the accent a step deeper so the line and the fills
/// hold 3:1 against the ground, and dark text on them stays at 4.5:1 or better. Every text tone is
/// 4.5:1 or better on the surfaces it is drawn on. `UIParityTests` measures the pairs.
enum LDTone {
    static let ground = BrandTone(light: 0xF3F6F4, dark: 0x0A0F0D)
    static let text = BrandTone(light: 0x101A15, dark: 0xEEF4F0)
    static let accent = BrandTone(light: 0x1E9665, dark: 0x30B77E)
    static let accentDim = BrandTone(light: 0x63B797, dark: 0x1F7A55)
    static let accentText = BrandTone(light: 0x176B49, dark: 0x6FE0AE)
    static let accentTextSoft = BrandTone(light: 0x1B6F4D, dark: 0x8FDDB8)
    static let onAccent = BrandTone(light: 0x06130D, dark: 0x06130D)
    static let icon = BrandTone(light: 0x1B7A54, dark: 0x4FD19A)
    static let muted = BrandTone(light: 0x56645D, dark: 0xA7B5AE)
    static let secondary = BrandTone(light: 0x46534C, dark: 0xB9C4BE)
    static let inactive = BrandTone(light: 0x3E4B44, dark: 0xC7D2CC)
    static let tile = BrandTone(light: 0xFFFFFF, dark: 0x141C18)
    static let tileBorder = BrandTone(light: 0xD5DED9, dark: 0x27332D)
    static let divider = BrandTone(light: 0xE1E7E3, dark: 0x222C27)
    static let hairline = BrandTone(light: 0xD5DED9, dark: 0x1E2A25)
    static let ghostBorder = BrandTone(light: 0xA9B8B0, dark: 0x33423B)
    static let warning = BrandTone(light: 0x955A00, dark: 0xF7C56C)
    static let warningText = BrandTone(light: 0x6E4A06, dark: 0xF7DFAE)
    static let warningSurface = BrandTone(light: 0xFBF3DF, dark: 0x1D1A10)
    static let warningBorder = BrandTone(light: 0xE3C98F, dark: 0x5A4620)
    static let flatLine = BrandTone(light: 0x7A8E83, dark: 0x3B5A4C)
    static let flatDim = BrandTone(light: 0xC6D3CB, dark: 0x26382F)
    static let sheet = BrandTone(light: 0xF8FAF9, dark: 0x0E1512)
    // Not in the brief's list, but drawn on the boards by gen_all.py.
    static let warningDim = BrandTone(light: 0xA97F2E, dark: 0x8A6524)
    static let warningBody = BrandTone(light: 0x5A4318, dark: 0xE9DDBF)
    static let optionOff = BrandTone(light: 0x7C8C84, dark: 0x5A6C63)
    static let progressTrack = BrandTone(light: 0xE2E9E5, dark: 0x1E2622)
}

/// The tokens as SwiftUI colours. Use these, never a literal, so a screen follows the Appearance
/// setting. `accentTextSoft` is the brief's second accent text, #8FDDB8.
enum LDTheme {
    static let ground = Color(LDTone.ground)
    static let text = Color(LDTone.text)
    static let accent = Color(LDTone.accent)
    static let accentDim = Color(LDTone.accentDim)
    static let accentText = Color(LDTone.accentText)
    static let accentTextSoft = Color(LDTone.accentTextSoft)
    static let onAccent = Color(LDTone.onAccent)
    static let icon = Color(LDTone.icon)
    static let muted = Color(LDTone.muted)
    static let secondary = Color(LDTone.secondary)
    static let inactive = Color(LDTone.inactive)
    static let tile = Color(LDTone.tile)
    static let tileBorder = Color(LDTone.tileBorder)
    static let divider = Color(LDTone.divider)
    static let hairline = Color(LDTone.hairline)
    static let ghostBorder = Color(LDTone.ghostBorder)
    static let warning = Color(LDTone.warning)
    static let warningText = Color(LDTone.warningText)
    static let warningSurface = Color(LDTone.warningSurface)
    static let warningBorder = Color(LDTone.warningBorder)
    static let flatLine = Color(LDTone.flatLine)
    static let flatDim = Color(LDTone.flatDim)
    static let sheet = Color(LDTone.sheet)
    static let warningDim = Color(LDTone.warningDim)
    static let warningBody = Color(LDTone.warningBody)
    static let optionOff = Color(LDTone.optionOff)
    static let progressTrack = Color(LDTone.progressTrack)

    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 20
    /// The side margin of cards, buttons and tiles.
    static let cardInset: CGFloat = 14
    /// The side margin of headings, labels and notes.
    static let textInset: CGFloat = 20
    /// The widest a screen's column gets, in landscape.
    static let readableWidth: CGFloat = 700
}
