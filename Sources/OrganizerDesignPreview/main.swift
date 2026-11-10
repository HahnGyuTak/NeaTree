import AppKit
import OrganizerDesignSystem
import SwiftUI

/// A visual component sample. This target has no dependency on OrganizerCore.
@main @MainActor
enum OrganizerDesignPreview {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let dark = arguments.contains("--dark")
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let view = DesignPreview()
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "파일 정리 — Liquid Glass 미리보기"
        window.appearance = NSAppearance(named: appearance)
        window.contentMinSize = NSSize(width: 840, height: 540)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        applicationMenu()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        // View snapshots are for inspecting layout; macOS composites some glass
        // and behind-window effects separately, so the live preview is authoritative.
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let output = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    fputs("미리보기 이미지를 만들지 못했습니다.\n", stderr)
                    NSApp.terminate(nil)
                    return
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                do {
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: output)
                    print(output.path)
                } catch { fputs("미리보기 이미지 저장 실패: \(error.localizedDescription)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func applicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "미리보기 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }
}

private struct DesignPreview: View {
    @State private var selection: String? = "review"
    @State private var result = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let items: [LiquidSidebarItem] = [
        .init(id: "review", title: "검토함", systemImage: "tray", count: 3),
        .init(id: "unclassified", title: "미분류", systemImage: "folder", count: 2),
        .init(id: "held", title: "보류", systemImage: "pause.circle", count: 1),
        .init(id: "history", title: "정리 이력", systemImage: "clock.arrow.circlepath"),
        .init(id: "rules", title: "분류 규칙", systemImage: "slider.horizontal.3")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                LiquidWindowControls()
                Text("파일 정리").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("검색 아이콘")
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(.ultraThinMaterial)

            LiquidSidebarLayout(items: items, selection: $selection) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(items.first(where: { $0.id == selection })?.title ?? "검토함")
                            .font(.system(size: 26, weight: .semibold))
                        Text("파일의 이름과 위치를 확인하세요.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    LiquidGlassGroup(spacing: 8) {
                        HStack(alignment: .top, spacing: 24) {
                            fileList
                                .frame(maxWidth: .infinity, alignment: .leading)
                            proposal
                                .frame(width: 310)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack {
                        Text(result.isEmpty ? "샘플 파일 3개" : result)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("다운로드")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            }
        }
        .liquidCustomTitlebar()
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("이름")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            row("다운로드한 문서.pdf", symbol: "doc.text", selected: true)
            row("회의 메모.txt", symbol: "doc.plaintext", selected: false)
            row("참고 자료", symbol: "folder", selected: false)
        }
    }

    @ViewBuilder private func row(_ name: String, symbol: String, selected: Bool) -> some View {
        let label = HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        if selected {
            label.liquidGlass(cornerRadius: 10)
        } else {
            label
        }
    }

    private var proposal: some View {
        VStack(alignment: .leading, spacing: 18) {
            LiquidGlassCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("정리 제안").font(.headline)
                            Text("PDF 문서").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    field("제안 이름", value: "002_프로젝트_견적서.pdf")
                    field("제안 위치", value: "문서 / 01_프로젝트 / 견적서")
                    Text("기존 프로젝트의 파일명과 번호 규칙을 따릅니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button("취소") { setResult("이번 제안을 보류했습니다.") }
                Spacer()
                Button("적용") { setResult("미리보기입니다. 실제 파일은 변경하지 않습니다.") }
            }
            .buttonStyle(LiquidGlassButtonStyle())
        }
    }

    private func field(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setResult(_ value: String) {
        withAnimation(reduceMotion ? nil : .liquidReveal) { result = value }
    }
}
