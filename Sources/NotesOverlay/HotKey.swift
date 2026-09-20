import AppKit
import Carbon

/// System-wide hotkey via Carbon's RegisterEventHotKey. Works for a background
/// accessory app and needs no Accessibility permission.
final class HotKey {
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: 0x4E4F_5445 /* 'NOTE' */, id: 1)

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Must be a C function pointer: no captures, `self` travels through userData.
        let handler: EventHandlerUPP = { _, event, userData in
            var id = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard err == noErr, let userData else { return err }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().fired(id)
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Replaces any currently registered combo. Returns the Carbon status;
    /// `eventHotKeyExistsErr` means another app or macOS already owns the combo.
    @discardableResult
    func register(_ combo: HotKeyCombo) -> OSStatus {
        unregister()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func fired(_ id: EventHotKeyID) {
        guard id.signature == hotKeyID.signature, id.id == hotKeyID.id else { return }
        onPressed?()
    }
}
