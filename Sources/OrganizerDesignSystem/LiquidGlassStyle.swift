import AppKit
import SwiftUI

// MARK: - Shared color and motion tokens

public extension Color {
    /// A neutral specular reflection, not an application accent color.
    static var liquidGlassHighlight: Color { .white }

    /// The opacity of the shadow is chosen by the consuming modifier.
    static var liquidGlassShadow: Color { .black }

    /// An adaptive opaque surface for Reduce Transparency and increased legibility.
    static var liquidGlassSurface: Color { Color(nsColor: .windowBackgroundColor) }
}

public extension Animation {
    /// A short, softly damped response for pointer and pressed states.
    static var liquidHover: Animation {
        .spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0.12)
    }

    /// Use with a matchedGeometryEffect selection shape, rather than animating text.
    static var liquidSelection: Animation {
        .spring(response: 0.42, dampingFraction: 0.84, blendDuration: 0.16)
    }

    /// A restrained expansion for a newly presented surface.
    static var liquidReveal: Animation {
        .spring(response: 0.46, dampingFraction: 0.86, blendDuration: 0.16)
    }
}

// MARK: - Optical layers

/// A thin top-lit edge. The overlay never changes hit testing or blurs its content.
public struct LiquidGlassHighlight: ViewModifier {
    public let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = max(0, cornerRadius)
    }

    public func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if contrast == .increased {
                shape.strokeBorder(Color.primary.opacity(0.48), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .liquidGlassHighlight.opacity(colorScheme == .dark ? 0.34 : 0.66),
                            .liquidGlassHighlight.opacity(0.06),
                            .liquidGlassShadow.opacity(colorScheme == .dark ? 0.20 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// A blurred dark gradient *behind* the surface. Content and text remain sharp.
public struct LiquidGlassShadow: ViewModifier {
    public let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = max(0, cornerRadius)
    }

    public func body(content: Content) -> some View {
        content.background {
            if !reduceTransparency && contrast != .increased {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .liquidGlassShadow.opacity(colorScheme == .dark ? 0.20 : 0.10)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.horizontal, 3)
                    .blur(radius: 9)
                    .offset(y: 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Native Liquid Glass on macOS 26 and newer, with an approximate material fallback.
///
/// `ultraThinMaterial` provides translucency and blur on older systems; it does not
/// reproduce the native Liquid Glass refraction engine. Neither branch blurs labels.
public struct LiquidGlassSurface: ViewModifier {
    public let cornerRadius: CGFloat
    public let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 14, tint: Color? = nil) {
        self.cornerRadius = max(0, cornerRadius)
        self.tint = tint
    }

    public func body(content: Content) -> some View {
        surface(content)
            .modifier(LiquidGlassShadow(cornerRadius: cornerRadius))
            .modifier(LiquidGlassHighlight(cornerRadius: cornerRadius))
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color.liquidGlassSurface, in: shape)
        } else if #available(macOS 26.0, *) {
            // The system supplies the actual refraction and adaptive optical response.
            // Do not place another material layer underneath this native glass surface.
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content.background {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        if let tint {
                            shape.fill(tint.opacity(0.10))
                        }
                    }
            }
        }
    }
}

// MARK: - Interaction

/// A tiny elastic expansion for a standalone interactive surface.
/// Use on controls, not long-form text or entire windows.
public struct LiquidGlassHoverEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: hovered && isEnabled && !reduceMotion ? 1.012 : 1,
                y: hovered && isEnabled && !reduceMotion ? 1.018 : 1
            )
            .animation(reduceMotion ? nil : .liquidHover, value: hovered && isEnabled)
            .onHover { hovered = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
    }
}

public extension View {
    func liquidGlass(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(LiquidGlassSurface(cornerRadius: cornerRadius, tint: tint))
    }

    func liquidHoverEffect() -> some View {
        modifier(LiquidGlassHoverEffect())
    }
}

/// A glass control with restrained liquid hover/press movement and system text colors.
public struct LiquidGlassButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonBody(configuration: configuration)
    }
}

private struct LiquidGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var expanded: Bool { hovered && isEnabled && !configuration.isPressed }

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(cornerRadius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(
                x: reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.975 : expanded ? 1.012 : 1),
                y: reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.965 : expanded ? 1.022 : 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .liquidHover, value: expanded)
            .animation(reduceMotion ? nil : .liquidHover, value: configuration.isPressed)
            .onHover { hovered = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
    }
}

/// A reusable content surface. Place neighboring glass surfaces in LiquidGlassGroup.
public struct LiquidGlassCard<Content: View>: View {
    public let cornerRadius: CGFloat
    public let padding: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = 18,
        padding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = max(0, cornerRadius)
        self.padding = max(0, padding)
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: cornerRadius)
    }
}

/// Shares the native sampling region between neighboring glass elements.
/// Keep `spacing` below the actual gaps if the elements should remain separate at rest.
public struct LiquidGlassGroup<Content: View>: View {
    public let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = max(0, spacing)
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
