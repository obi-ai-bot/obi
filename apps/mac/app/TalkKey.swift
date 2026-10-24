import AppKit
import ApplicationServices
import CoreGraphics

/// Hold fn (or Control-Option, on keyboards without fn) to talk to Oby; let go to send.
/// fn + Space keeps listening hands-free until fn is pressed again (⌃⌥Space stays macOS's: it
/// switches input sources, and it's VoiceOver's main command). Control-Option is off while
/// VoiceOver runs, since its users hold it for every command. An active event tap on
/// the session, so it needs Accessibility; fn's own events are swallowed so the Globe key's
/// action (emoji, dictation) doesn't fire, if macOS lets an event tap stop it (see `GlobeKey`).
final class TalkKey {
    enum Key { case fn, controlOption }
    /// `press` comes the moment a talk key goes down, before anything else is known (it may turn
    /// out to be a shortcut): the reply the pill shows goes on it.
    enum Event { case press(Key), start(Key), handsFree, send, cancel }

    var on: (Event) -> Void = { _ in }

    private var tap: CFMachPort?
    private var retry: Timer?
    /// The key held down now, unless another key made it a shortcut (fn-F1, Control-Option-→).
    private var held: Key?
    /// `.start` went out, and neither `.send` nor `.cancel` since.
    private var talking = false
    private var handsFree = false
    private var controlOptionDown = false
    /// The Space that turned on hands-free: its key up is ours too.
    private var swallowSpaceUp = false
    /// A short hold before the microphone opens, so fn and Control-Option shortcuts never open it.
    private var wait: Task<Void, Never>?

    private static let fnCode: Int64 = 63
    private static let spaceCode: Int64 = 49
    private static let escapeCode: Int64 = 53

    /// Installs the tap, or tries again until Accessibility is allowed. Oby asks for it in first
    /// launch's fn step, with its reason, and never by itself.
    func start() {
        guard tap == nil, retry == nil, !install() else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.install() else { return }
                self.retry?.invalidate()
                self.retry = nil
            }
        }
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: talkKeyEvent,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        // Common modes, so the keys still work while an alert of Oby's is up.
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// One keyboard event; true swallows it.
    func handle(_ type: CGEventType, code: Int64, flags: CGEventFlags, repeating: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off: turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged where code == Self.fnCode:
            if flags.contains(.maskSecondaryFn) { press(.fn) } else { release(.fn) }
            return true
        case .flagsChanged:
            let modifiers = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            let down = modifiers == [.maskControl, .maskAlternate]
            guard down != controlOptionDown else { return false }
            controlOptionDown = down
            if down {
                press(.controlOption)
            } else if modifiers.isSuperset(of: [.maskControl, .maskAlternate]) {
                // Command or Shift joined a held Control-Option: a shortcut, not talk.
                if held == .controlOption { spoil() }
            } else {
                release(.controlOption)
            }
            return false
        case .keyDown where code == Self.spaceCode && held == .fn:
            if !repeating { keepListening() }
            swallowSpaceUp = true
            return true
        case .keyUp where code == Self.spaceCode && swallowSpaceUp:
            swallowSpaceUp = false
            return true
        case .keyDown where code == Self.escapeCode && talking:
            stop(.cancel)
            return true
        case .keyDown where held != nil, .leftMouseDown where held != nil, .rightMouseDown where held != nil, .otherMouseDown where held != nil:
            // fn or Control-Option was part of a shortcut, or a click or drag: not talk.
            spoil()
            return false
        default:
            return false
        }
    }

    /// A talk key is down, or a turn it started is under way: the microphone is the user's now.
    var busy: Bool { held != nil || talking }

    /// Oby's reply showed in hands-free mode and it listens again for yours: the next press of
    /// either key sends, as after fn + Space, and Escape cancels. Never while a key is down or a
    /// turn is under way: that press is the user's own, and its release must still close the
    /// microphone. False then, and nothing changes.
    func listenAgain() -> Bool {
        guard !busy else { return false }
        talking = true
        handsFree = true
        return true
    }

    private func press(_ key: Key) {
        on(.press(key))
        // Hands-free ends at the next press, of either key.
        if handsFree { stop(.send); return }
        guard held == nil, !talking else { return }
        if key == .controlOption, NSWorkspace.shared.isVoiceOverEnabled { return }
        held = key
        wait?.cancel()
        wait = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, held == key, !talking else { return }
            talking = true
            on(.start(key))
        }
    }

    private func release(_ key: Key) {
        guard held == key else { return }
        held = nil
        wait?.cancel()
        if talking, !handsFree { stop(.send) }
    }

    /// The held key turned out to be part of a shortcut: whatever it started is cancelled, not sent.
    private func spoil() {
        if talking, !handsFree { stop(.cancel) }
        held = nil
        wait?.cancel()
    }

    /// fn + Space: listening goes on after the key is let go, until it's pressed again.
    private func keepListening() {
        guard let key = held else { return }
        wait?.cancel()
        if !talking {
            talking = true
            on(.start(key))
        }
        held = nil
        handsFree = true
        on(.handsFree)
    }

    private func stop(_ event: Event) {
        talking = false
        handsFree = false
        held = nil
        wait?.cancel()
        on(event)
    }
}

/// The tap's callback, on the main run loop: it can't capture anything, so the TalkKey comes in `refcon`.
nonisolated private func talkKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<TalkKey>.fromOpaque(refcon).takeUnretainedValue()
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let flags = event.flags
    let swallow = MainActor.assumeIsolated { keys.handle(type, code: code, flags: flags, repeating: repeating) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// macOS's own action for the Globe key. Whether swallowing fn in the tap stops it is unproven,
/// so the first time you talk with fn, Oby shows you once where to turn it off.
enum GlobeKey {
    /// "Press 🌐 key to" in Keyboard settings: 0 is Do Nothing.
    static var acts: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) != 0
    }

    static func guideOnce() {
        let shown = "globeKeyGuideShown"
        guard acts, !UserDefaults.standard.bool(forKey: shown) else { return }
        UserDefaults.standard.set(true, forKey: shown)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let fn talk only to Oby"
        alert.informativeText = "macOS can also show emoji or start dictation when you press fn. In Keyboard settings, set “Press 🌐 key to” to Do Nothing."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
