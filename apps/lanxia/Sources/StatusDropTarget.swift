import AppKit

@MainActor
final class StatusDropTarget: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    private var hoverTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Wings，打开文件中转站")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        cancelHover()
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            guard let window = self.window, window.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
            let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            guard self.visibleRect.contains(self.convert(location, from: nil)) else { return }
            self.onHover?()
        }
    }

    override func mouseExited(with event: NSEvent) { cancelHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        cancelHover()
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        cancelHover()
        onClick?()
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        cancelHover()
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
    }
}
