import AppKit
import SwiftUI

extension EnvironmentValues {
    var dwellToOpenEnabled: Bool {
        get { self[DwellEnabledKey.self] }
        set { self[DwellEnabledKey.self] = newValue }
    }

    var dwellPreview: DwellPreview? {
        get { self[DwellPreviewKey.self] }
        set { self[DwellPreviewKey.self] = newValue }
    }
}

private struct DwellEnabledKey: EnvironmentKey { static let defaultValue = true }
private struct DwellPreviewKey: EnvironmentKey { static let defaultValue: DwellPreview? = nil }

extension Notification.Name {
    static let cancelDwellActivation = Self("StashCatCancelDwellActivation")
}

@MainActor
final class DwellPreview: ObservableObject {
    @Published private(set) var target: String?
    private var owner: UUID?
    private var activationLocation: CGPoint?

    func canStart(at location: CGPoint) -> Bool {
        guard let activationLocation else { return true }
        return hypot(location.x - activationLocation.x, location.y - activationLocation.y) >= 5
    }

    func show(_ target: String, owner: UUID) {
        self.owner = owner
        self.target = target
    }

    func finish(owner: UUID, at location: CGPoint) -> Bool {
        guard self.owner == owner else { return false }
        activationLocation = location
        clear(owner: owner)
        return true
    }

    func clear(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        target = nil
    }
}

/// Gives an opening or navigation action the same behavior for click and dwell.
struct DwellButton<Label: View>: View {
    let target: String
    var allowsDwell = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.dwellToOpenEnabled) private var dwellToOpenEnabled
    @Environment(\.dwellPreview) private var preview
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = DwellActivation()
    @State private var owner = UUID()
    @State private var isCountingDown = false

    private var canDwell: Bool { dwellToOpenEnabled && isEnabled && allowsDwell }
    private var highlight: RoundedRectangle { RoundedRectangle(cornerRadius: 7) }

    var body: some View {
        Button {
            cancelDwell()
            action()
        } label: {
            label().contentShape(Rectangle())
        }
        .overlay {
            if isCountingDown {
                highlight
                    .fill(.primary.opacity(0.10))
                    .overlay(highlight.strokeBorder(.primary.opacity(0.42), lineWidth: 1))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(.primary.opacity(0.82))
                .frame(height: 2)
                .scaleEffect(x: isCountingDown ? 1 : 0, y: 1, anchor: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: beginHover()
            case .ended: endHover()
            }
        }
        .onChange(of: canDwell) { _, allowed in
            if !allowed { cancelDwell() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelDwellActivation)) { _ in cancelDwell() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelDwell() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelDwell() }
        .onDisappear(perform: endHover)
    }

    private func beginHover() {
        guard canDwell, NSEvent.pressedMouseButtons == 0,
              preview?.canStart(at: NSEvent.mouseLocation) != false else { return }
        let started = activation.pointerEntered {
            isCountingDown = false
            guard NSEvent.pressedMouseButtons == 0 else { preview?.clear(owner: owner); return }
            if let preview, !preview.finish(owner: owner, at: NSEvent.mouseLocation) { return }
            action()
        }
        if started {
            preview?.show(target, owner: owner)
            withAnimation(reduceMotion ? nil : .linear(duration: DwellActivation.delay.timeInterval)) {
                isCountingDown = true
            }
        }
    }

    private func cancelDwell() {
        guard isCountingDown else { return }
        activation.cancel()
        isCountingDown = false
        preview?.clear(owner: owner)
    }

    private func endHover() {
        activation.pointerExited()
        isCountingDown = false
        preview?.clear(owner: owner)
    }
}

struct DwellMenu<Label: View, MenuContent: View>: View {
    let target: String
    @ViewBuilder let content: (_ dismiss: @escaping () -> Void) -> MenuContent
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        DwellButton(target: target, allowsDwell: !isPresented, action: { isPresented.toggle() }) {
            label()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                content { isPresented = false }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }
}

private extension Duration {
    var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
