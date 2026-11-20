import SwiftUI
import AppKit

struct ThemeSettings: Codable, Equatable {
    var accent = "80E8C4"
    var background = "0E131B"
    var surface = "181F28"
    var text = "F4F7FA"
    var muted = "91A6B5"
    static let presets: [(String, ThemeSettings)] = [
        ("薄荷", ThemeSettings()),
        ("海蓝", ThemeSettings(accent: "72B9FF", background: "0C1420", surface: "172638", text: "F1F7FF", muted: "91ADC9")),
        ("紫罗兰", ThemeSettings(accent: "C4A0FF", background: "16111F", surface: "261D33", text: "F8F2FF", muted: "B2A0C4")),
        ("琥珀", ThemeSettings(accent: "F4C56B", background: "19150E", surface: "2C2519", text: "FFF8EA", muted: "BCAF96")),
        ("纸白", ThemeSettings(accent: "096A60", background: "F4F6F8", surface: "FFFFFF", text: "18242C", muted: "586B78"))
    ]
    static func normalizedHex(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return value
    }
    var valid: Bool { [accent, background, surface, text, muted].allSatisfy { Self.normalizedHex($0) != nil } }
}
struct BoardPalette {
    let theme: ThemeSettings
    init(_ theme: ThemeSettings = ThemeSettings()) { self.theme = theme.valid ? theme : ThemeSettings() }
    static func color(_ hex: String) -> Color {
        let n = UInt64(ThemeSettings.normalizedHex(hex) ?? "80E8C4", radix: 16) ?? 0
        return Color(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "80E8C4" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    var background: Color { Self.color(theme.background) }
    var card: Color { Self.color(theme.surface) }
    var accent: Color { Self.color(theme.accent) }
    var text: Color { Self.color(theme.text) }
    var muted: Color { Self.color(theme.muted) }
    var isLight: Bool {
        let n = UInt64(theme.background, radix: 16) ?? 0
        return (Double((n >> 16) & 255) * 0.2126 + Double((n >> 8) & 255) * 0.7152 + Double(n & 255) * 0.0722) > 155
    }
    func color(_ state: TaskState) -> Color { switch state { case .running, .completed: return accent; case .waiting: return .orange; case .failed: return .red; default: return muted } }
}
