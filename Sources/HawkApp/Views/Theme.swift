//
//  Theme.swift
//  Hawk
//
//  Colours, type and spacing, in one place. Like drake, Hawk is always dark: a
//  near-black body, white text, one cool blue accent. Each measured quantity
//  keeps the same colour everywhere (chart line, legend dot, meter), so a
//  colour means one thing across the window.
//

import SwiftUI

enum Palette {
    static let background = Color(white: 0.035)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.08)
    static let grid = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)

    // One colour per quantity.
    static let eCore = Color(red: 0.25, green: 0.85, blue: 0.75)
    static let pCore = accent
    static let gpu = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let soc = Color(red: 1.0, green: 0.55, blue: 0.25)
    static let ssd = Color(red: 0.45, green: 0.85, blue: 0.42)
    static let battery = Color(red: 1.0, green: 0.82, blue: 0.30)
    static let power = Color(red: 1.0, green: 0.82, blue: 0.30)
    static let download = Color(red: 0.30, green: 0.78, blue: 1.0)
    static let upload = Color(red: 1.0, green: 0.45, blue: 0.65)
    static let diskRead = Color(red: 0.45, green: 0.85, blue: 0.42)
    static let diskWrite = Color(red: 1.0, green: 0.55, blue: 0.25)
    static let memApp = accent
    static let memWired = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let memCompressed = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let memCached = Color.white.opacity(0.28)
    static let fanLeft = Color(red: 0.25, green: 0.85, blue: 0.75)
    static let fanRight = Color(red: 0.36, green: 0.62, blue: 1.0)

    static let good = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.25)
    static let hot = Color(red: 1.0, green: 0.36, blue: 0.36)

    /// Low to high load or heat.
    static let heatGradient = Gradient(colors: [good, warn, hot])
    /// Fan speed is not good or bad, so its gauge uses cool tones.
    static let fanGradient = Gradient(colors: [eCore, accent, gpu])
    /// Battery charge: empty is the alarming end.
    static let chargeGradient = Gradient(colors: [hot, warn, good])

    static func load(_ x: Double) -> Color { x >= 0.85 ? hot : x >= 0.6 ? warn : good }

    static func heat(_ c: Double?) -> Color {
        guard let c else { return secondary }
        return c >= 85 ? hot : c >= 65 ? warn : good
    }
}

enum Typography {
    static let cardTitle = Font.system(size: 11, weight: .semibold)
    static let hero = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    static let large = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    static let value = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()
    static let label = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let caption = Font.system(size: 10, weight: .medium).monospacedDigit()
    static let code = Font.system(size: 11, design: .monospaced)
}

enum Metrics {
    static let spacing: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let minCardWidth: CGFloat = 340
    /// Room for the traffic lights, since the title bar is hidden.
    static let titleBarInset: CGFloat = 78
    /// Charts never draw more points than this per series, whatever the range.
    static let maxChartPoints = 120
}
