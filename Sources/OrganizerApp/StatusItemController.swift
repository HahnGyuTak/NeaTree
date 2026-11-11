import AppKit
import Combine
import OrganizerAppSupport
import OrganizerDesignSystem
import ServiceManagement
import SwiftUI

/// Menu bar mockup v1 approved by the user on 2026-11-11.
enum DesignReviewStatus {
    static let menuBarProposalApproved = true
}

@MainActor
final class OrganizerStatusController: NSObject {
    private let model: OrganizerAppModel
    private let onOpenMain: () -> Void
    private let item: NSStatusItem
    private var panel: ProposalPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(model: OrganizerAppModel, onOpenMain: @escaping () -> Void) {
        self.model = model
        self.onOpenMain = onOpenMain
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "FileOrganizerStatusItem"
        if let button = item.button {
            button.image = OrganizerArtwork.menuBarIcon()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("NeaTree 메뉴바")
        }
        Publishers.CombineLatest3(model.$entries, model.$watching, model.$isBusy)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &subscriptions)
        updateStatus()
    }

    func updateStatus() {
        let count = model.pendingCount
        item.button?.title = count > 0 ? " \(count)" : ""
        item.button?.toolTip = "NeaTree · \(model.watching ? "다운로드 감시 중" : "감시 일시중지") · \(count)개 대기"
        item.button?.setAccessibilityValue(model.isBusy ? "작업 중" : "\(count)개 대기")
    }

    func proposalBecameReady(_ id: UUID) {
        updateStatus()
        guard DesignReviewStatus.menuBarProposalApproved else { return }
        // Do not replace a proposal the user is already reading.
        guard panel?.isVisible != true else { return }
        // The frontmost main window already presents the same queue.
        guard !NSApp.isActive || NSApp.keyWindow == nil else { return }
        model.selectedItemID = id
        showProposal(allowKeyboardFocus: false)
    }

    func stop() {
        dismissProposal()
        subscriptions.removeAll()
        NSStatusBar.system.removeStatusItem(item)
    }

    func showFromUserAction() {
        showProposal(allowKeyboardFocus: true)
    }

    func dismissProposal() {
        panel?.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    @objc private func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if panel?.isVisible == true {
            dismissProposal()
        } else if DesignReviewStatus.menuBarProposalApproved || model.isDemo {
            showProposal(allowKeyboardFocus: true)
        } else {
            onOpenMain()
        }
    }

    private func showProposal(allowKeyboardFocus: Bool) {
        guard let button = item.button, let anchorWindow = button.window,
              anchorWindow.isVisible, anchorWindow.occlusionState.contains(.visible),
              let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor.width > 0, anchor.height > 0, screen.frame.intersects(anchor) else { return }
        let width: CGFloat = 380
        let x = min(max(anchor.midX - width / 2, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        let tip = min(max(anchor.midX - x, 22), width - 22)
        let panel = self.panel ?? ProposalPanel()
        panel.allowsKeyboardFocus = allowKeyboardFocus
        let hostingView = NSHostingView(rootView:
            ProposalCallout(tipX: tip) {
                ProposalPopoverView(model: model, onOpenMain: { [weak self] in
                    self?.dismissProposal()
                    self?.onOpenMain()
                })
            }
        )
        panel.contentView = hostingView
        let height = min(max(hostingView.fittingSize.height, 180), screen.visibleFrame.height - 16)
        let y = max(screen.visibleFrame.minY + 8, anchor.minY - height - 3)
        let finalFrame = NSRect(x: x, y: y, width: width, height: height)
        self.panel = panel
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.setFrame(reduceMotion ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 6), display: true)
        // Automatic proposals preserve the other app's focus. An explicit click
        // opts into keyboard navigation without activating the main window.
        if allowKeyboardFocus { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            }
        }
        installDismissalMonitors()
    }

    private func installDismissalMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissProposal() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismissProposal() }
                } else if event.window !== self.panel && event.window !== self.item.button?.window {
                    self.dismissProposal()
                }
            }
            return event
        }
    }

    private func showContextMenu() {
        dismissProposal()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeItem("검토함 열기", action: #selector(openMain)))
        menu.addItem(makeItem("설정…", action: #selector(openSettings)))
        menu.addItem(.separator())
        let watch = makeItem(model.watching ? "다운로드 감시 일시중지" : "다운로드 감시 시작", action: #selector(toggleWatching))
        watch.isEnabled = model.settings != nil
        menu.addItem(watch)
        let login = makeItem(SMAppService.mainApp.status == .requiresApproval ? "로그인 시 실행 — 승인 필요…" : "로그인 시 실행", action: #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = !model.isDemo
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(makeItem("NeaTree 종료", action: #selector(quit)))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        return result
    }

    @objc private func openMain() { onOpenMain() }
    @objc private func openSettings() {
        onOpenMain()
        NotificationCenter.default.post(name: Notification.Name("OrganizerOpenSettings"), object: nil)
    }
    @objc private func toggleWatching() { model.setWatching(!model.watching) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLoginItem() {
        guard !model.isDemo else { return }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    model.statusMessage = "시스템 설정의 로그인 항목에서 백그라운드 실행을 허용해 주세요."
                    onOpenMain()
                }
            }
        } catch {
            model.errorMessage = "로그인 실행 설정을 변경하지 못했습니다: \(error.localizedDescription)"
            onOpenMain()
        }
    }
}

@MainActor
private final class ProposalPanel: NSPanel {
    var allowsKeyboardFocus = false
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

private struct ProposalCallout<Content: View>: View {
    let tipX: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 11)
            content
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CalloutMaterial(tipX: tipX, opaque: reduceTransparency))
    }
}

private struct CalloutMaterial: ViewModifier {
    let tipX: CGFloat
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        let shape = ProposalCalloutShape(tipX: tipX)
        if opaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct ProposalCalloutShape: Shape {
    var tipX: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: max(0, rect.height - 10)), cornerRadius: 18)
        path.move(to: CGPoint(x: tipX - 10, y: rect.minY + 12))
        path.addLine(to: CGPoint(x: tipX, y: rect.minY))
        path.addLine(to: CGPoint(x: tipX + 10, y: rect.minY + 12))
        path.closeSubpath()
        return path
    }
}
