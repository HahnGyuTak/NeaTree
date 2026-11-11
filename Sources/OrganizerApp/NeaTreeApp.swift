import AppKit
import Combine
import OrganizerAppSupport
import ServiceManagement
import SwiftUI

@main @MainActor
enum NeaTreeApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = OrganizerApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class OrganizerApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: OrganizerAppModel?
    private var mainWindow: NSWindow?
    private var statusController: OrganizerStatusController?
    private var initialLoad: Task<Void, Never>?
    private var pendingOpenURLs: [URL] = []
    private var modelStarted = false
    private var drainingOpenURLs = false
    private var intakeObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        OrganizerArtwork.installDevelopmentAppIcon()
        do {
            let arguments = CommandLine.arguments
            let demo = arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "FileOrganizerDemoMode") as? Bool == true
            let directory: URL
            if let index = arguments.firstIndex(of: "--state"), index + 1 < arguments.count {
                directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("FileOrganizer", isDirectory: true)
            }
            let model = try OrganizerAppModel(stateDirectory: directory, demo: demo)
            self.model = model
            intakeObservation = Publishers.CombineLatest(model.$isBusy, model.$settings)
                .receive(on: RunLoop.main)
                .sink { [weak self] busy, settings in
                    guard !busy, settings != nil, let self, self.modelStarted else { return }
                    Task { await self.importPendingURLs() }
                }
            installMenu()
            statusController = OrganizerStatusController(model: model, onOpenMain: { [weak self] in self?.showMainWindow() })
            model.onProposalReady = { [weak self] id in self?.statusController?.proposalBecameReady(id) }
            initialLoad = Task { [weak self] in
                await model.start()
                guard !Task.isCancelled, let self else { return }
                self.modelStarted = true
                self.statusController?.updateStatus()
                if !self.pendingOpenURLs.isEmpty { await self.importPendingURLs() }
            }
            let launchedAsLoginItem = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            if !arguments.contains("--background") && !launchedAsLoginItem { showMainWindow() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "NeaTree를 시작하지 못했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls.filter(\.isFileURL))
        showMainWindow()
        if modelStarted { Task { await importPendingURLs() } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        initialLoad?.cancel()
        intakeObservation = nil
        statusController?.stop()
        model?.stop()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(menuItem("검토함 열기", action: #selector(openReview)))
        return menu
    }

    private func importPendingURLs() async {
        guard let model, !pendingOpenURLs.isEmpty, !drainingOpenURLs, !model.isBusy else { return }
        guard model.settings != nil else {
            model.statusMessage = "먼저 관리할 폴더를 설정하세요. 열린 파일은 설정 완료 후 검토함에 추가합니다."
            return
        }
        drainingOpenURLs = true
        defer { drainingOpenURLs = false }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        await model.importFiles(urls)
        if !pendingOpenURLs.isEmpty {
            Task { [weak self] in await self?.importPendingURLs() }
        }
    }

    func showMainWindow() {
        guard let model else { return }
        statusController?.dismissProposal()
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = model.isDemo ? "NeaTree — 데모" : "NeaTree"
            window.contentView = NSHostingView(rootView: OrganizerMainView(model: model))
            window.contentMinSize = NSSize(width: 960, height: 620)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(menuItem("NeaTree에 관하여", action: #selector(showAbout)))
        app.addItem(.separator())
        app.addItem(menuItem("설정…", action: #selector(openSettings), key: ","))
        app.addItem(.separator())
        app.addItem(menuItem("NeaTree 가리기", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        app.addItem(menuItem("NeaTree 종료", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        let appItem = NSMenuItem()
        appItem.submenu = app
        menu.addItem(appItem)
        let edit = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(menuItem("검토함 열기", action: #selector(openReview), key: "1"))
        windowMenu.addItem(menuItem("메뉴바 제안 보기", action: #selector(openProposal), key: "2"))
        windowMenu.addItem(NSMenuItem(title: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem(title: "윈도우", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    private func menuItem(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func openReview() {
        showMainWindow()
        NotificationCenter.default.post(name: Notification.Name("OrganizerShowReview"), object: nil)
    }

    @objc private func openSettings() {
        showMainWindow()
        NotificationCenter.default.post(name: Notification.Name("OrganizerOpenSettings"), object: nil)
    }

    @objc private func openProposal() { statusController?.showFromUserAction() }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NeaTree",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 중",
            .credits: NSAttributedString(string: "Neat + Tree · 깔끔한 디렉토리 구조\nGitHub Releases로 배포하는 macOS 파일 정리 도우미\nhttps://github.com/HahnGyuTak/NeaTree")
        ])
    }
}
