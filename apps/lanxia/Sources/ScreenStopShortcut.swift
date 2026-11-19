import AppKit
import Carbon

private final class ScreenStopShortcutCallback: @unchecked Sendable {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}

/// A single registered hotkey, not a keyboard event tap or a keystroke monitor.
@MainActor
final class ScreenStopShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: ScreenStopShortcutCallback
    private(set) var isRegistered = false

    init(action: @escaping @MainActor () -> Void) {
        callback = ScreenStopShortcutCallback(action)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let reference = Unmanaged.passUnretained(callback).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard status == noErr, identity.signature == 0x53544353, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
            let callback = Unmanaged<ScreenStopShortcutCallback>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in callback.action() }
            return noErr
        }, 1, &event, reference, &handler)
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x53544353, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey), identifier,
                                        GetApplicationEventTarget(), 0, &hotKey)
        isRegistered = result == noErr
        if !isRegistered, let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
