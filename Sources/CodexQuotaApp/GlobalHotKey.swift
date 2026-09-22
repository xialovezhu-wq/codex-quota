import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private static let signature = OSType(0x43515154)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let identifier: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void

    init(
        identifier: UInt32,
        keyCode: UInt32,
        modifiers: UInt32 = UInt32(controlKey | optionKey),
        handler: @escaping () -> Void
    ) {
        self.identifier = identifier
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    @discardableResult
    func register() -> Bool {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard
                    status == noErr,
                    pressedID.signature == GlobalHotKey.signature,
                    pressedID.id == hotKey.identifier
                else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    hotKey.handler()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            unregister()
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
    }
}
