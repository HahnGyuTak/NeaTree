import AppKit
import SwiftUI

/// Custom glass traffic lights for a custom title bar.
///
/// The default initializer addresses this view's own hosting window. It never
/// uses `NSApp.keyWindow`, so a control in one window cannot close another.
/// The green `+` calls `performZoom`, meaning zoom/restore, not full screen.
/// These are app-owned controls, not a reproduction of private macOS artwork.
@MainActor
public struct LiquidWindowControls: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var target = LiquidWindowTarget()
    @State private var isHovered = false
    @FocusState private var focusedControl: LiquidWindowControl?

    private let actions: LiquidWindowActions?

    /// Resolves the containing window automatically after this view is mounted.
    public init() {
        actions = nil
    }

    /// Callback mode for previews or a host that already owns its window.
    /// Callers should capture an `NSWindow` weakly when a window owns this view.
    public init(
        onClose: @escaping @MainActor () -> Void,
        onMinimize: @escaping @MainActor () -> Void,
        onZoom: @escaping @MainActor () -> Void,
        canClose: Bool = true,
        canMinimize: Bool = true,
        canZoom: Bool = true
    ) {
        actions = LiquidWindowActions(
            close: onClose, minimize: onMinimize, zoom: onZoom,
            capabilities: .init(close: canClose, minimize: canMinimize, zoom: canZoom)
        )
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(LiquidWindowControl.allCases) { control in
                let enabled = isEnabled && capabilities.allows(control)
                Button {
                    perform(control)
                } label: {
                    LiquidTrafficLightFace(
                        control: control,
                        hovered: isHovered,
                        focused: focusedControl == control,
                        enabled: enabled
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidTrafficLightPressStyle())
                .disabled(!enabled)
                .focused($focusedControl, equals: control)
                .help(control.label)
                .accessibilityLabel(Text(control.label))
                .accessibilityHint(Text(control.hint))
                .accessibilityIdentifier("liquid-window-\(control.rawValue)")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .liquidHover, value: isHovered)
        .background {
            if actions == nil {
                LiquidWindowProbe(target: target)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("창 제어"))
    }

    private var capabilities: LiquidWindowCapabilities {
        actions?.capabilities ?? target.capabilities
    }

    private func perform(_ control: LiquidWindowControl) {
        guard isEnabled, capabilities.allows(control) else { return }
        if let actions {
            switch control {
            case .close: actions.close()
            case .minimize: actions.minimize()
            case .zoom: actions.zoom()
            }
        } else {
            // Re-check the actual window at the moment of activation, too.
            target.perform(control)
        }
    }
}

private enum LiquidWindowControl: String, CaseIterable, Identifiable {
    case close, minimize, zoom
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .minimize: "minus"
        case .zoom: "plus"
        }
    }

    var color: Color {
        switch self {
        case .close: Color(nsColor: .systemRed)
        case .minimize: Color(nsColor: .systemYellow)
        case .zoom: Color(nsColor: .systemGreen)
        }
    }

    var label: String {
        switch self {
        case .close: "닫기"
        case .minimize: "최소화"
        case .zoom: "창 확대 또는 원래 크기"
        }
    }

    var hint: String {
        switch self {
        case .close: "이 창을 닫습니다. 앱 종료와는 다릅니다."
        case .minimize: "이 창을 Dock으로 최소화합니다."
        case .zoom: "이 창의 확대 상태를 전환합니다."
        }
    }
}

@MainActor
private struct LiquidTrafficLightFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let control: LiquidWindowControl
    let hovered: Bool
    let focused: Bool
    let enabled: Bool

    private var revealed: Bool { hovered && enabled }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.clear)
                .frame(width: 14, height: 14)
                .liquidGlass(cornerRadius: 7)
                .overlay {
                    Circle()
                        .fill(control.color.opacity(revealed ? 0.94 : 0))
                }
                .overlay {
                    // Gloss belongs to the surface; text and symbols stay sharp.
                    Circle().fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(revealed ? 0.58 : 0.25),
                                .white.opacity(revealed ? 0.10 : 0.03),
                                .clear,
                                .black.opacity(revealed ? 0.13 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(reduceTransparency ? 0 : 1)
                }
                .overlay {
                    Circle().strokeBorder(
                        contrast == .increased
                            ? Color.primary.opacity(0.62)
                            : Color.white.opacity(revealed ? 0.55 : 0.30),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
                }
                .overlay {
                    Image(systemName: control.symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.78))
                        .opacity(revealed ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .scaleEffect(reduceMotion ? 1 : (revealed ? 1.045 : 1))
                .opacity(enabled ? 1 : 0.38)

            // Keyboard focus remains visible without making hover-only icons
            // permanently visible. The system accent is a focus affordance.
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 21, height: 21)
                .opacity(focused && enabled ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private struct LiquidTrafficLightPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.93 : 1))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? .easeOut(duration: 0.10) : .liquidHover,
                value: configuration.isPressed
            )
    }
}

private struct LiquidWindowCapabilities: Equatable {
    var close = false
    var minimize = false
    var zoom = false

    func allows(_ control: LiquidWindowControl) -> Bool {
        switch control {
        case .close: close
        case .minimize: minimize
        case .zoom: zoom
        }
    }
}

@MainActor
private struct LiquidWindowActions {
    let close: @MainActor () -> Void
    let minimize: @MainActor () -> Void
    let zoom: @MainActor () -> Void
    let capabilities: LiquidWindowCapabilities
}

@MainActor
private final class LiquidWindowTarget: ObservableObject {
    private weak var window: NSWindow?
    @Published private(set) var capabilities = LiquidWindowCapabilities()

    func attach(_ window: NSWindow?) {
        self.window = window
        refresh()
    }

    private func refresh() {
        let updated: LiquidWindowCapabilities
        if let window {
            updated = .init(
                close: window.styleMask.contains(.closable)
                    && (window.standardWindowButton(.closeButton)?.isEnabled ?? true),
                minimize: window.styleMask.contains(.miniaturizable)
                    && (window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? true),
                zoom: window.styleMask.contains(.resizable)
                    && (window.standardWindowButton(.zoomButton)?.isEnabled ?? true)
            )
        } else {
            updated = .init()
        }
        if capabilities != updated { capabilities = updated }
    }

    func perform(_ control: LiquidWindowControl) {
        refresh()
        guard let window, capabilities.allows(control) else { return }
        switch control {
        case .close: window.performClose(nil)
        case .minimize: window.performMiniaturize(nil)
        case .zoom: window.performZoom(nil)
        }
    }
}

@MainActor
private struct LiquidWindowProbe: NSViewRepresentable {
    let target: LiquidWindowTarget

    func makeNSView(context: Context) -> LiquidWindowAttachmentView {
        let view = LiquidWindowAttachmentView()
        view.didAttach = { [weak target] window in target?.attach(window) }
        return view
    }

    func updateNSView(_ nsView: LiquidWindowAttachmentView, context: Context) {
        nsView.scheduleAttachmentUpdate()
    }

    static func dismantleNSView(_ nsView: LiquidWindowAttachmentView, coordinator: ()) {
        nsView.didAttach?(nil)
        nsView.didAttach = nil
    }
}

/// Opt in once at the root of a window that supplies its own title bar.
/// Closing/minimizing/zooming capabilities remain unchanged. Removing the
/// modifier restores the native controls and the properties it changed.
public extension View {
    func liquidCustomTitlebar() -> some View {
        background {
            LiquidCustomTitlebarConfigurator()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private struct LiquidCustomTitlebarConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiquidWindowAttachmentView {
        let view = LiquidWindowAttachmentView()
        view.didAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        return view
    }

    func updateNSView(_ nsView: LiquidWindowAttachmentView, context: Context) {
        nsView.scheduleAttachmentUpdate()
    }

    static func dismantleNSView(_ nsView: LiquidWindowAttachmentView, coordinator: Coordinator) {
        nsView.didAttach = nil
        coordinator.restore()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var snapshot: Snapshot?

        func attach(_ newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            restore()
            guard let newWindow, newWindow.styleMask.contains(.titled) else { return }
            window = newWindow
            snapshot = Snapshot(window: newWindow)
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            for kind in Snapshot.buttonKinds {
                newWindow.standardWindowButton(kind)?.isHidden = true
            }
        }

        func restore() {
            guard let window, let snapshot else {
                window = nil
                snapshot = nil
                return
            }
            if !snapshot.hadFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
            window.titleVisibility = snapshot.titleVisibility
            window.titlebarAppearsTransparent = snapshot.transparentTitlebar
            for (index, kind) in Snapshot.buttonKinds.enumerated() {
                if let wasHidden = snapshot.buttonsHidden[index] {
                    window.standardWindowButton(kind)?.isHidden = wasHidden
                }
            }
            self.window = nil
            self.snapshot = nil
        }
    }

    @MainActor
    private struct Snapshot {
        static let buttonKinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let hadFullSizeContent: Bool
        let titleVisibility: NSWindow.TitleVisibility
        let transparentTitlebar: Bool
        let buttonsHidden: [Bool?]

        init(window: NSWindow) {
            hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
            titleVisibility = window.titleVisibility
            transparentTitlebar = window.titlebarAppearsTransparent
            buttonsHidden = Self.buttonKinds.map { window.standardWindowButton($0)?.isHidden }
        }
    }
}

@MainActor
private final class LiquidWindowAttachmentView: NSView {
    var didAttach: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttachmentUpdate()
    }

    func scheduleAttachmentUpdate() {
        // Avoid publishing SwiftUI state while a representable update is active.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            didAttach?(window)
        }
    }
}
