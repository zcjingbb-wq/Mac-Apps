import AppKit
import SwiftUI

private let panelCornerRadius: CGFloat = 24

/// The panel's single, native backdrop. Hosting views belong to contentView so
/// AppKit always composites controls above the glass rather than behind it.
@MainActor final class GlassPanelHost: NSView {
    private var hostedContent: NSView
    private var backdrop: NSView?
    private var presentation: Presentation?
    private var displayObserver: NSObjectProtocol?

    private enum Presentation { case glass, material, solid }

    init(content: NSView) {
        hostedContent = content
        super.init(frame: content.frame)
        autoresizingMask = [.width, .height]
        rebuildBackdropIfNeeded()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildBackdropIfNeeded() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayObserver)
        }
    }

    override var isOpaque: Bool { false }

    func setContent(_ content: NSView) {
        // Avoid tearing down SwiftUI state (including active dictation) when
        // merely revealing the already-visible page.
        guard hostedContent !== content else { return }
        hostedContent.removeFromSuperview()
        hostedContent = content
        installContent()
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        if let backdrop { hostedContent.frame = backdrop.bounds }
    }

    private func rebuildBackdropIfNeeded() {
        let workspace = NSWorkspace.shared
        let next: Presentation
        if workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast {
            next = .solid
        } else if #available(macOS 26.0, *) {
            next = .glass
        } else {
            next = .material
        }
        guard presentation != next else { return }
        hostedContent.removeFromSuperview()
        backdrop?.removeFromSuperview()

        let view: NSView
        if #available(macOS 26.0, *), next == .glass {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = panelCornerRadius
            view = glass
        } else if next == .material {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = panelCornerRadius
            material.layer?.masksToBounds = true
            view = material
        } else {
            let solid = SolidPanelBackdrop(frame: bounds)
            view = solid
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        backdrop = view
        presentation = next
        installContent()
    }

    private func installContent() {
        guard let backdrop else { return }
        hostedContent.frame = backdrop.bounds
        hostedContent.autoresizingMask = [.width, .height]
        hostedContent.translatesAutoresizingMaskIntoConstraints = true
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.contentView = hostedContent
        } else {
            backdrop.addSubview(hostedContent)
        }
        needsLayout = true
    }
}

/// Dynamic system colors keep the accessibility fallback readable in either
/// appearance, without changing any of the user's global display settings.
private final class SolidPanelBackdrop: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: panelCornerRadius, yRadius: panelCornerRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension View {
    /// Cards share the panel's glass and use a translucent fill for separation.
    /// Solid system surfaces take precedence for accessibility.
    func stashGlassSurface(cornerRadius: CGFloat = 14, emphasis: Bool = false) -> some View {
        modifier(StashGlassSurface(cornerRadius: cornerRadius, emphasis: emphasis))
    }

    /// A quiet highlight over the native backdrop, never an opaque second fill.
    func stashGlassPanelEdge(cornerRadius: CGFloat = panelCornerRadius) -> some View {
        modifier(StashGlassPanelEdge(cornerRadius: cornerRadius))
    }

    func stashGlassPrimaryButton() -> some View {
        modifier(StashGlassPrimaryButton())
    }

    /// Crisp, lightly embossed lettering for titles and important values.
    /// Call this selectively so inverted action-button labels keep their color.
    func stashHighlightedText() -> some View {
        modifier(StashHighlightedText())
    }
}

private struct StashGlassPrimaryButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct StashGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let emphasis: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var fillOpacity: Double {
        if colorScheme == .dark { return emphasis ? 0.32 : 0.18 }
        return emphasis ? 0.38 : 0.23
    }

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 1))
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(fillOpacity), in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.34 : 0.75), location: 0),
                            .init(color: .white.opacity(colorScheme == .dark ? 0.08 : 0.25), location: 0.32),
                            .init(color: .primary.opacity(colorScheme == .dark ? 0.085 : 0.12), location: 0.80),
                            .init(color: .white.opacity(colorScheme == .dark ? 0.17 : 0.48), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: emphasis ? 1 : 0.75)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

private struct StashGlassPanelEdge: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var usesSolidSurface: Bool { reduceTransparency || contrast == .increased }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if !usesSolidSurface {
                    ZStack {
                        if #available(macOS 26.0, *) {
                            // Clear glass exposes more of the desktop. The scheme-matched
                            // backing keeps labels legible across varied wallpapers.
                            shape.fill(Color(nsColor: .windowBackgroundColor)
                                .opacity(colorScheme == .dark ? 0.66 : 0.74))
                        }
                        GeometryReader { geometry in
                            shape.fill(RadialGradient(
                                colors: [Color(red: 0.83, green: 0.95, blue: 1)
                                    .opacity(colorScheme == .dark ? 0.07 : 0.15), .clear],
                                center: .topLeading, startRadius: 0,
                                endRadius: min(geometry.size.width * 0.77, 360)
                            ))
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipShape(shape)
            .overlay {
                if usesSolidSurface {
                    shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.65 : 0.22),
                                       lineWidth: contrast == .increased ? 1.5 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    shape.strokeBorder(LinearGradient(stops: [
                        .init(color: .white.opacity(colorScheme == .dark ? 0.63 : 0.95), location: 0),
                        .init(color: .white.opacity(colorScheme == .dark ? 0.18 : 0.46), location: 0.28),
                        .init(color: .primary.opacity(colorScheme == .dark ? 0.09 : 0.15), location: 0.71),
                        .init(color: .white.opacity(colorScheme == .dark ? 0.32 : 0.64), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct StashHighlightedText: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.foregroundStyle(.primary)
        } else {
            content
                .foregroundStyle(.primary)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.46) : .white.opacity(0.82),
                        radius: 0, x: 0, y: colorScheme == .dark ? 1 : 0.5)
        }
    }
}
