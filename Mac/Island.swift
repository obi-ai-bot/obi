import AppKit
import SwiftUI
import WebKit

enum IslandState { case compact, peek, open }

/// The island's state and its geometry, measured from the screen Oby lives on.
@Observable
final class IslandModel {
    var state: IslandState = .compact
    /// The notch's size, or zero on a screen without one.
    var notch: CGSize = .zero
    /// The menu bar's height, used for the pill on screens without a notch.
    var barHeight: CGFloat = 24

    private let wing: CGFloat = 52
    private var top: CGFloat { notch == .zero ? barHeight : notch.height }

    var size: CGSize {
        let base = notch == .zero ? 180 : notch.width + 2 * wing
        switch state {
        case .compact: return CGSize(width: base, height: top)
        case .peek: return CGSize(width: base + 140, height: top + 6)
        case .open: return CGSize(width: 560, height: top + 126)
        }
    }

    var radius: CGFloat {
        switch state {
        case .compact: 12
        case .peek: 18
        case .open: 32
        }
    }

    /// Where Oby sits inside the island, from its top-left corner.
    var characterFrame: CGRect {
        switch state {
        case .compact, .peek: CGRect(x: 8, y: -3, width: top + 6, height: top + 6)
        // Oby's body sits low in its frame (room to jump), so the frame starts under the notch.
        case .open: CGRect(x: 14, y: top - 14, width: 136, height: 136)
        }
    }

    var contentTop: CGFloat { top }
}

/// Pins the island to the top center of the screen with the notch (or the main screen),
/// above the menu bar, on every Space, and passes clicks through everywhere else.
final class IslandController {
    let model = IslandModel()
    let character = ObyCharacter()
    private let panel = NotchPanel()
    private var timer: Timer?
    private var lastMouse: CGPoint?
    private var clickMonitor: Any?

    func start() {
        panel.contentView = NSHostingView(rootView: IslandView(
            model: model, character: character,
            onOpen: { [weak self] in self?.open() },
            onClose: { [weak self] in self?.close() }))
        place()
        panel.orderFrontRegardless()
        character.pause(true)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // ponytail: polling the mouse at 30 Hz is cheaper than it sounds and needs no permission
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A click in another app closes the open island. Clicks on the island are ours and never arrive here.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func open() { set(.open) }
    func close() { if model.state == .open { set(.compact) } }

    private func set(_ state: IslandState) {
        guard model.state != state else { return }
        model.state = state
        character.pause(state == .compact)
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func place() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notch = .zero
        }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        model.barHeight = bar > 0 ? bar : NSStatusBar.system.thickness
        let size = CGSize(width: 640, height: 320)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private var islandRect: NSRect {
        let size = model.size
        return NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let island = islandRect
        let inside = island.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        switch model.state {
        case .compact where inside: set(.peek)
        case .peek where !inside: set(.compact)
        default: break
        }
        guard model.state != .compact, mouse != lastMouse else { return }
        lastMouse = mouse
        // oby.html reads the pointer relative to its own frame, which is tiny here: scale the
        // distance from Oby so far-away pointers turn the head a little, not all the way round.
        let frame = model.characterFrame
        let x = max(-1, min(1, (mouse.x - (island.minX + frame.midX)) / 420))
        let y = max(-1, min(1, ((island.maxY - frame.midY) - mouse.y) / 260))
        character.point(at: CGPoint(x: (x + 1) / 2 * frame.width, y: (y + 1) / 2 * frame.height))
    }
}

/// A borderless panel that never activates Oby, so whatever you're working in keeps focus.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
}

struct IslandView: View {
    let model: IslandModel
    let character: ObyCharacter
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        let size = model.size
        let frame = model.characterFrame
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: model.radius, bottomTrailingRadius: model.radius, style: .continuous)

        ZStack(alignment: .topLeading) {
            // The shadow belongs to the static shape only: on the whole island it would be
            // recomputed on every one of Oby's frames.
            shape.fill(.black)
                .shadow(color: .black.opacity(model.state == .open ? 0.5 : 0), radius: 30, y: 14)

            WebView(character.page)
                .webViewContentBackground(.hidden)
                .allowsHitTesting(model.state == .open)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityLabel("Oby")

            if model.state == .peek {
                HStack {
                    Text("Oby").font(.system(size: 12, weight: .semibold))
                        .padding(.leading, frame.maxX + 4)
                    Spacer()
                    Text("All quiet").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.trailing, 14)
                }
                .frame(height: size.height)
                .transition(.opacity)
            }

            if model.state == .open {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All quiet.").font(.system(size: 19, weight: .semibold))
                    Text("Nothing needs you.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.leading, frame.maxX + 2)
                .padding(.top, model.contentTop + 44)
                .transition(.opacity)

                Button(action: onClose) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .frame(width: size.width - 16, alignment: .trailing)
                .padding(.top, model.contentTop + 10)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .onTapGesture { if model.state != .open { onOpen() } }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
