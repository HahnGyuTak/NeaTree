import AppKit
import QuickLookUI
import SwiftUI

@MainActor
struct QuickLookPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            NativeQuickLookView(url: url)
                .accessibilityLabel("원본 파일 미리보기")
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 560)
    }
}

@MainActor
private struct NativeQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
