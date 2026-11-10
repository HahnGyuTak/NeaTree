import AppKit
import SwiftUI

/// A navigation destination. IDs must be unique within one sidebar.
public struct LiquidSidebarItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let count: Int?

    public init(id: String, title: String, systemImage: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }
}

/// A sidebar with independent selection and hover highlights.
///
/// The AppKit backing view uses behind-window vibrancy rather than an opaque
/// SwiftUI background. For desktop colors to contribute, its hosting window
/// must use `isOpaque = false` and `backgroundColor = .clear`, and the host must
/// not insert an opaque view behind this sidebar. Accessibility settings and
/// macOS control the final amount of transparency.
public struct LiquidSidebar: View {
    public let items: [LiquidSidebarItem]
    @Binding private var selection: String?

    @State private var hoveredID: String?
    @FocusState private var focusedID: String?
    @Namespace private var highlightSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(items: [LiquidSidebarItem], selection: Binding<String?>) {
        self.items = items
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.vertical) {
            LiquidGlassGroup(spacing: 6) {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        navigationButton(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SidebarWindowMaterial()
            }
        }
        .animation(reduceMotion ? nil : .liquidSelection, value: selection)
        .animation(reduceMotion ? nil : .liquidHover, value: hoveredID)
        .accessibilityLabel("사이드바")
    }

    private func navigationButton(_ item: LiquidSidebarItem) -> some View {
        let isSelected = selection == item.id
        return Button {
            selection = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count = item.count {
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                highlight(for: item, selected: isSelected)
                    .allowsHitTesting(false)
            }
            // GlassEffectContainer must receive the complete foreground label.
            // Applying glass only to a background shape can make the label part
            // of the material's sampled backdrop instead of keeping it crisp.
            .modifier(SidebarSelectionGlass(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .focused($focusedID, equals: item.id)
        .overlay {
            if focusedID == item.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.65), lineWidth: 1.5)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isInside in
            if isInside {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.count.map { "\($0)개" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func highlight(for item: LiquidSidebarItem, selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(contrast == .increased ? 0.18 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.12), lineWidth: 0.75)
                }
                .matchedGeometryEffect(id: "selection", in: highlightSpace)
                .transition(.opacity)
        } else if hoveredID == item.id {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(contrast == .increased ? 0.12 : 0.045))
                .matchedGeometryEffect(id: "hover", in: highlightSpace)
                .transition(.opacity)
        }
        // Selection and hover have different identities. A selected row never
        // renders a second hover source, so transitions cannot match two sources.
    }
}

/// A restrained sidebar + content shell. The caller owns its titlebar and content.
/// Main content stays on a readable system surface; reserve extra glass cards
/// for groups that actually need a distinct visual hierarchy.
public struct LiquidSidebarLayout<Content: View>: View {
    private let items: [LiquidSidebarItem]
    @Binding private var selection: String?
    private let sidebarWidth: CGFloat
    private let content: Content

    public init(
        items: [LiquidSidebarItem],
        selection: Binding<String?>,
        sidebarWidth: CGFloat = 220,
        @ViewBuilder content: () -> Content
    ) {
        self.items = items
        self._selection = selection
        self.sidebarWidth = max(160, sidebarWidth)
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            LiquidSidebar(items: items, selection: $selection)
                .frame(width: sidebarWidth)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarSelectionGlass: ViewModifier {
    let isSelected: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isSelected {
            content.liquidGlass(cornerRadius: 10)
        } else {
            content
        }
    }
}

private struct SidebarWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}
