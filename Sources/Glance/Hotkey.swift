import Carbon

/// Global hotkey via Carbon. Works in every app and needs no permission.
/// Reports both press and release so hold-to-talk can be added later (Phase 2).
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Called with the event's own timestamp (seconds since boot).
    fileprivate let onPress: (TimeInterval) -> Void
    fileprivate let onRelease: (TimeInterval) -> Void

    init(keyCode: UInt32, modifiers: UInt32 = UInt32(optionKey),
         onPress: @escaping (TimeInterval) -> Void, onRelease: @escaping (TimeInterval) -> Void = { _ in }) {
        self.onPress = onPress
        self.onRelease = onRelease

        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let time = GetEventTime(event)
            MainActor.assumeIsolated { pressed ? hotkey.onPress(time) : hotkey.onRelease(time) }
            return noErr
        }, types.count, &types, selfPtr, &handler)

        let id = EventHotKeyID(signature: OSType(0x474C_4E43), id: 1) // 'GLNC'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
