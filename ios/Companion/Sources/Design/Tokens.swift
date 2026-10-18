import SwiftUI

// Sought design tokens. Source of truth is the Figma file "Sought / SoughtBot" (Home hi-fi, Item Log).
// Three text colors are darker than Figma for WCAG contrast (approved by Isaac): status line, screen titles,
// Call Soughtbot fill. Every view reads colors from `Palette` through the environment so the high contrast
// setting can swap the whole set at once.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

struct Palette {
    // Surfaces
    var background: Color          // Home, Map, Settings
    var backgroundAlt: Color       // Item Log
    var band: Color                // alternating Item Log sections
    var surface: Color             // map floor, photo placeholder
    var card: Color                // solid fallback for glass
    // Text
    var title: Color               // "Welcome Luca", "What are we seeking today?"
    var sectionTitle: Color        // "Recent Finds"
    var text: Color                // card titles and meta, status line
    var textOnDark: Color
    var placeholder: Color
    // Accents
    var primary: Color             // Find it, primary buttons
    var call: Color                // Call Soughtbot
    var activityText: Color
    var activityFill: Color
    var searchFill: Color
    var micFill: Color
    var tabGlass: Color
    var tabGradientTop: Color
    var tabGradientBottom: Color
    var mapRoom: Color
    var mapWall: Color
    var mapPath: Color
    var signal: Color              // only while Soughtbot is actively doing something; never text, never a large fill
    var searching: Color
    var found: Color
    var alert: Color
    var photoShade: Color          // bottom gradient on photos

    static let standard = Palette(
        background: Color(hex: 0xD6E8EC), backgroundAlt: Color(hex: 0xD9E3ED), band: Color(hex: 0xC8DAE4),
        surface: Color(hex: 0xEEF4F5), card: Color(hex: 0xE3EEF1),
        title: Color(hex: 0x3E7C8A), sectionTitle: Color(hex: 0x2E4A66), text: Color(hex: 0x24414B),
        textOnDark: Color(hex: 0xFAFCFC), placeholder: Color(hex: 0x434C4E),
        primary: Color(hex: 0x24414B), call: Color(hex: 0x2F6672),
        activityText: Color(hex: 0x0B5F66), activityFill: Color(red: 150 / 255, green: 226 / 255, blue: 238 / 255, opacity: 0.2),
        searchFill: Color(red: 152 / 255, green: 193 / 255, blue: 205 / 255, opacity: 0.15),
        micFill: Color(red: 152 / 255, green: 193 / 255, blue: 205 / 255, opacity: 0.26),
        tabGlass: Color(red: 87 / 255, green: 169 / 255, blue: 178 / 255, opacity: 0.2),
        tabGradientTop: Color(red: 187 / 255, green: 203 / 255, blue: 204 / 255, opacity: 0),
        tabGradientBottom: Color(hex: 0x57A9B2),
        mapRoom: Color(hex: 0xE3EBED), mapWall: Color(hex: 0xA9C3CA), mapPath: Color(hex: 0x0E7C86),
        signal: Color(hex: 0x22D3EE), searching: Color(hex: 0xB7790F), found: Color(hex: 0x1F9D6B), alert: Color(hex: 0xC8412C),
        photoShade: Color(hex: 0x0F1E24))

    // High contrast: the dark token set from the plan (night background, glacier text).
    static let highContrast = Palette(
        background: Color(hex: 0x0F1E24), backgroundAlt: Color(hex: 0x0F1E24), band: Color(hex: 0x172C34),
        surface: Color(hex: 0x1C343D), card: Color(hex: 0x1C343D),
        title: Color(hex: 0xD6E8EC), sectionTitle: Color(hex: 0xEEF4F5), text: Color(hex: 0xEEF4F5),
        textOnDark: Color(hex: 0xFFFFFF), placeholder: Color(hex: 0xC4D6DB),
        primary: Color(hex: 0xD6E8EC), call: Color(hex: 0x9DBDC6),
        activityText: Color(hex: 0xEEF4F5), activityFill: Color(hex: 0x1C343D),
        searchFill: Color(hex: 0x1C343D), micFill: Color(hex: 0x24414B),
        tabGlass: Color(hex: 0x24414B), tabGradientTop: Color(hex: 0x0F1E24, alpha: 0), tabGradientBottom: Color(hex: 0x0F1E24),
        mapRoom: Color(hex: 0x24414B), mapWall: Color(hex: 0x9DBDC6), mapPath: Color(hex: 0x3CC4D4),
        signal: Color(hex: 0x3CC4D4), searching: Color(hex: 0xF2B84B), found: Color(hex: 0x4FD19A), alert: Color(hex: 0xFF8A75),
        photoShade: Color(hex: 0x000000))

    /// Text drawn on `primary` / `call` fills.
    var onPrimary: Color { self.background == Palette.highContrast.background ? Color(hex: 0x0F1E24) : Color(hex: 0xFAFCFC) }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.standard }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Type

enum SoughtFont {
    // Font.custom(_:size:relativeTo:) keeps Dynamic Type scaling.
    static let screenTitle = Font.custom("Geist-Regular", size: 24, relativeTo: .title2)
    static let sectionTitle = Font.custom("Geist-Regular", size: 24, relativeTo: .title2)
    static let largeTitle = Font.custom("Geist-Medium", size: 28, relativeTo: .largeTitle)
    static let body = Font.custom("Geist-Regular", size: 17, relativeTo: .body)
    static let bodyMedium = Font.custom("Geist-Medium", size: 17, relativeTo: .body)
    static let status = Font.custom("Geist-Regular", size: 12, relativeTo: .caption)
    static let search = Font.custom("Geist-Light", size: 15, relativeTo: .subheadline)
    static let searchHero = Font.custom("Geist-Regular", size: 17, relativeTo: .body)
    static let cardTitle = Font.custom("Geist-SemiBold", size: 12, relativeTo: .footnote)
    static let cardMeta = Font.custom("Geist-Light", size: 12, relativeTo: .footnote)
    static let activityHeading = Font.custom("Geist-SemiBold", size: 14, relativeTo: .subheadline)
    static let activityBody = Font.custom("Geist-Regular", size: 16, relativeTo: .callout)
    static let activityMeta = Font.custom("Geist-Light", size: 14, relativeTo: .subheadline)
    static let liveView = Font.custom("Geist-Bold", size: 20, relativeTo: .title3)
    static let findIt = Font.custom("JetBrainsMono-Medium", size: 12, relativeTo: .footnote)
    static let callButton = Font.custom("JetBrainsMono-Bold", size: 16, relativeTo: .callout)
    static let mapLabel = Font.custom("JetBrainsMono-BoldItalic", size: 24, relativeTo: .title2)
    static let readout = Font.custom("JetBrainsMono-Bold", size: 13, relativeTo: .footnote)
    static let badge = Font.custom("JetBrainsMono-Bold", size: 11, relativeTo: .caption2)
    static let bigReadout = Font.custom("JetBrainsMono-Bold", size: 56, relativeTo: .largeTitle)
    static let button = Font.custom("JetBrainsMono-Bold", size: 17, relativeTo: .body)
}

// MARK: - Layout

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48
    static let margin: CGFloat = 24
}

/// Corner radii, always drawn as continuous (squircle) corners. Rounder than the Figma's 8 for an Apple feel
/// (Isaac, 2026-10-17). Nested shapes stay concentric: inner radius = outer radius - padding between them.
enum Radius {
    static let card: CGFloat = 26      // big cards: map widget, Call, Activity, Live View, map card, robot card
    static let photo: CGFloat = 20     // carousel photos, large photos inside screens
    static let row: CGFloat = 20       // list rows, pin card
    static let tile: CGFloat = 16      // small count tiles
    static let thumb: CGFloat = 12     // thumbnails inside rows (row 20 - padding 8)
    // Buttons are capsules.
}

/// One motion language for the whole app. Reduce Motion swaps these for plain fades at the call site.
enum Motion {
    static let spring = Animation.spring(duration: 0.38, bounce: 0.18)
    static let quick = Animation.easeOut(duration: 0.2)
    static let fade = Animation.easeInOut(duration: 0.25)
}

extension View {
    /// The one soft shadow from the plan: y 8, blur 24, about 8 percent black.
    func softShadow() -> some View { shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8) }
}
