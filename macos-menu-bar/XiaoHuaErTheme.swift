import AppKit
import SwiftUI

enum XiaoHuaErTheme {
    static let radius: CGFloat = 8
    static let smallRadius: CGFloat = 6
    static let glassRadius: CGFloat = 30
    static let glassControlRadius: CGFloat = 17

    static let tint = adaptiveColor(
        light: NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.45, alpha: 1),
        dark: NSColor(calibratedRed: 0.45, green: 0.82, blue: 0.74, alpha: 1)
    )
    static let onTint = adaptiveColor(
        light: NSColor.white,
        dark: NSColor(calibratedWhite: 0.08, alpha: 1)
    )
    static let coral = adaptiveColor(
        light: NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.33, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.52, blue: 0.54, alpha: 1)
    )
    static let amber = adaptiveColor(
        light: NSColor(calibratedRed: 0.78, green: 0.48, blue: 0.12, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
    )
    static let sky = adaptiveColor(
        light: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.74, alpha: 1),
        dark: NSColor(calibratedRed: 0.48, green: 0.74, blue: 1.00, alpha: 1)
    )
    static let plum = adaptiveColor(
        light: NSColor(calibratedRed: 0.52, green: 0.36, blue: 0.73, alpha: 1),
        dark: NSColor(calibratedRed: 0.74, green: 0.62, blue: 0.96, alpha: 1)
    )
    static let leaf = adaptiveColor(
        light: NSColor(calibratedRed: 0.30, green: 0.56, blue: 0.23, alpha: 1),
        dark: NSColor(calibratedRed: 0.56, green: 0.84, blue: 0.46, alpha: 1)
    )

    static let surface = adaptiveColor(
        light: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.97, alpha: 1),
        dark: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 1)
    )
    static let elevatedSurface = adaptiveColor(
        light: NSColor(calibratedRed: 1.00, green: 1.00, blue: 0.99, alpha: 1),
        dark: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.19, alpha: 1)
    )
    static let recessedSurface = adaptiveColor(
        light: NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.94, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1)
    )
    static let border = adaptiveColor(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.14)
    )
    static let subtleBorder = adaptiveColor(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.07),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.09)
    )
    static let softShadow = adaptiveColor(
        light: NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.36, alpha: 0.16),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.45)
    )
    static let glassHairline = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.86),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.12)
    )
    static let glassWhitewash = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.82),
        dark: NSColor(calibratedWhite: 0.16, alpha: 0.72)
    )
    static let glassPanelFill = adaptiveColor(
        light: NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.98, alpha: 0.74),
        dark: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.19, alpha: 0.82)
    )
    static let glassToolbarFill = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.72),
        dark: NSColor(calibratedWhite: 0.18, alpha: 0.80)
    )
    static let glassFieldFill = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.66),
        dark: NSColor(calibratedWhite: 0.10, alpha: 0.58)
    )
    static let glassHighlightStart = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.48),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.08)
    )
    static let glassHighlightEnd = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.18),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.03)
    )
    static let liquidBase = adaptiveColor(
        light: NSColor(calibratedRed: 0.918, green: 0.941, blue: 0.953, alpha: 1),
        dark: NSColor(calibratedRed: 0.078, green: 0.089, blue: 0.102, alpha: 1)
    )
    static let liquidSkyGlow = adaptiveColor(
        light: NSColor(calibratedRed: 0.812, green: 0.878, blue: 1.0, alpha: 0.42),
        dark: NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.62, alpha: 0.28)
    )
    static let liquidWarmGlow = adaptiveColor(
        light: NSColor(calibratedRed: 0.976, green: 0.898, blue: 0.776, alpha: 0.38),
        dark: NSColor(calibratedRed: 0.46, green: 0.26, blue: 0.17, alpha: 0.22)
    )
    static let liquidLeafGlow = adaptiveColor(
        light: NSColor(calibratedRed: 0.847, green: 0.941, blue: 0.886, alpha: 0.46),
        dark: NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.28, alpha: 0.26)
    )
    static let liquidWash = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.60),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.18)
    )

    static func actionAccent(index: Int) -> Color {
        let colors = [tint, sky, coral, amber, plum, leaf]
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    static func actionFill(_ accent: Color) -> Color {
        accent.opacity(0.16)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }

    static func appKitGlassPanelFill(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.19, alpha: 0.82)
        }
        return NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.98, alpha: 0.74)
    }

    static func appKitGlassHairline(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedWhite: 1.0, alpha: 0.12)
        }
        return NSColor(calibratedWhite: 1.0, alpha: 0.86)
    }
}

enum CompanionGlassButtonTone: Equatable {
    case neutral
    case primary
    case danger
    case amber

    var fill: Color {
        switch self {
        case .neutral:
            return XiaoHuaErTheme.glassWhitewash
        case .primary:
            return XiaoHuaErTheme.tint.opacity(0.92)
        case .danger:
            return XiaoHuaErTheme.coral.opacity(0.92)
        case .amber:
            return XiaoHuaErTheme.amber.opacity(0.92)
        }
    }

    var foreground: Color {
        switch self {
        case .neutral:
            return .primary
        case .primary, .danger, .amber:
            return XiaoHuaErTheme.onTint
        }
    }
}

struct CompanionGlassButtonStyle: ButtonStyle {
    var tone: CompanionGlassButtonTone = .neutral
    var minWidth: CGFloat = 76
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: tone == .neutral ? .medium : .semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: minWidth, minHeight: height)
            .contentShape(Capsule(style: .continuous))
            .background(
                Capsule(style: .continuous)
                    .fill(tone.fill)
                    .shadow(color: XiaoHuaErTheme.softShadow.opacity(tone == .neutral ? 0.45 : 0.6), radius: 12, x: 0, y: 7)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct CompanionGlassIconButtonStyle: ButtonStyle {
    var tone: CompanionGlassButtonTone = .neutral
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(tone.fill)
                    .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.45), radius: 10, x: 0, y: 6)
            )
            .overlay(Circle().stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct CompanionStatusTag: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1))
    }
}

struct CompanionLiquidWindowBackground: View {
    var body: some View {
        ZStack {
            XiaoHuaErTheme.liquidBase
            LinearGradient(
                colors: [
                    XiaoHuaErTheme.liquidSkyGlow,
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            LinearGradient(
                colors: [
                    XiaoHuaErTheme.liquidWarmGlow,
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .center
            )
            LinearGradient(
                colors: [
                    Color.clear,
                    XiaoHuaErTheme.liquidLeafGlow
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            XiaoHuaErTheme.liquidWash
        }
        .ignoresSafeArea()
    }
}

struct CompanionGlassPanelBackground: View {
    var radius: CGFloat = XiaoHuaErTheme.glassRadius
    var liquidOpacity: Double = 0.20
    var shadowRadius: CGFloat = 30
    var shadowOpacity: Double = 0.35
    var shadowY: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 1)
            )
            .shadow(
                color: XiaoHuaErTheme.softShadow.opacity(shadowOpacity),
                radius: shadowRadius,
                x: 0,
                y: shadowY
            )
    }
}

struct CompanionTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            CompanionTrafficLight(color: Color(nsColor: NSColor.systemRed), action: { window?.performClose(nil) })
            CompanionTrafficLight(color: Color(nsColor: NSColor.systemYellow), action: { window?.miniaturize(nil) })
            CompanionTrafficLight(color: Color(nsColor: NSColor.systemGreen), action: { window?.zoom(nil) })
        }
    }

    @Environment(\.companionWindow) private var window
}

private struct CompanionTrafficLight: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(XiaoHuaErTheme.subtleBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct CompanionWindowEnvironmentKey: EnvironmentKey {
    static let defaultValue: NSWindow? = nil
}

extension EnvironmentValues {
    var companionWindow: NSWindow? {
        get { self[CompanionWindowEnvironmentKey.self] }
        set { self[CompanionWindowEnvironmentKey.self] = newValue }
    }
}

struct CompanionWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

extension View {
    func companionGlassSurface(radius: CGFloat = XiaoHuaErTheme.glassRadius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(XiaoHuaErTheme.glassPanelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        XiaoHuaErTheme.glassHighlightStart,
                                        XiaoHuaErTheme.glassHighlightEnd
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
            )
            .shadow(color: XiaoHuaErTheme.softShadow.opacity(0.35), radius: 30, x: 0, y: 18)
    }

    func companionGlassPanel(
        radius: CGFloat = XiaoHuaErTheme.glassRadius,
        liquidOpacity: Double = 0.20,
        shadowRadius: CGFloat = 30,
        shadowOpacity: Double = 0.35,
        shadowY: CGFloat = 18
    ) -> some View {
        self.background(
            CompanionGlassPanelBackground(
                radius: radius,
                liquidOpacity: liquidOpacity,
                shadowRadius: shadowRadius,
                shadowOpacity: shadowOpacity,
                shadowY: shadowY
            )
        )
    }

    func companionGlassField(radius: CGFloat = 18) -> some View {
        self
            .background(XiaoHuaErTheme.glassFieldFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
            )
    }

    func xiaoHuaErPanel(radius: CGFloat = XiaoHuaErTheme.radius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(XiaoHuaErTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(XiaoHuaErTheme.border, lineWidth: 1)
            )
    }

    func xiaoHuaErBubble(accent: Color = XiaoHuaErTheme.tint) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                    .fill(XiaoHuaErTheme.elevatedSurface)
                    .shadow(color: XiaoHuaErTheme.softShadow, radius: 18, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: XiaoHuaErTheme.radius, style: .continuous)
                    .stroke(XiaoHuaErTheme.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(accent)
                    .frame(width: 54, height: 3)
                    .padding(.top, 1)
                    .padding(.leading, 12)
            }
    }
}
