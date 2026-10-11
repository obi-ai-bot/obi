import AppKit
import Carbon.HIToolbox

/// ⌃⌥⌘. stops every job, on this Mac and on the runner, from whatever app is in front. A Carbon
/// hot key: it needs no permission (unlike the talk key's event tap), and macOS hands the press
/// to Oby alone.
final class StopAllKey {
    var on: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// "ObyS": the hot key's signature, so the handler knows the press is this one.
    nonisolated fileprivate static let signature: OSType = 0x4F62_7953

    func start() {
        guard hotKey == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), stopAllKeyEvent, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }
}

/// The hot key's handler, on the main thread: it can't capture anything, so the StopAllKey comes in `refcon`.
nonisolated private func stopAllKeyEvent(_ next: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == StopAllKey.signature else { return OSStatus(eventNotHandledErr) }
    let key = Unmanaged<StopAllKey>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { key.on() }
    return noErr
}
