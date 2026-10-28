import AppKit
import SwiftUI

/// Плашка внизу экрана, как у Wispr Flow и VoiceInk: видно, что идёт запись и что текст распознаётся.
final class RecordingHUD {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 360, height: 56)

    init(dictation: Dictation) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // не перехватывает клики и не забирает фокус у окна, куда вставляем
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(dictation: dictation))
    }

    func update(for state: Dictation.State) {
        hideWork?.cancel()
        switch state {
        case .recording, .sending, .formatting:
            show()
        case .failed:
            show()
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        case .idle:
            panel.orderOut(nil)
        }
    }

    private func show() {
        // Экран, где сейчас курсор: туда человек и смотрит.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 24))
        panel.orderFrontRegardless()
    }
}

struct HUDView: View {
    let dictation: Dictation

    var body: some View {
        HStack(spacing: 10) {
            switch dictation.state {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(dictation.levels.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(.white)
                            .frame(width: 3, height: 4 + CGFloat(level) * 22)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: dictation.levels)
            case .sending:
                ProgressView().controlSize(.small)
                Text("Распознаю…")
            case .formatting:
                ProgressView().controlSize(.small)
                Text("Оформляю…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
