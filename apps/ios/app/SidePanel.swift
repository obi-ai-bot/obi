import SwiftUI
import UIKit

/// What the side panel shows (Sangam's Sidebar.tsx): its icon strip picks Home's tasks or the
/// conversations; your picture at its foot opens Settings.
enum PanelSection: Hashable { case home, conversations }

/// Oby on iPhone with no tab bar (the owner's call, 2026-10-18, as Sangam's design has none): Home
/// and everything opened over it in one stack, and Sangam's side panel. It opens from the left and
/// pushes the view over: the panel button at Home's top left, or a swipe from the screen's left
/// edge on Home; a tap on what it pushed aside, a swipe back on it, the panel's own button, or
/// VoiceOver's escape closes it. With Reduce Motion it appears and goes without sliding.
struct PhoneRoot: View {
    @Environment(Phone.self) private var phone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let character: ObyCharacter
    /// How far a drag has moved the panel from where it rests.
    @GestureState private var drag: CGFloat = 0
    /// How far a swipe from the screen's edge has pulled it out.
    @State private var edge: CGFloat = 0

    var body: some View {
        if phone.needsPairing {
            // A fresh iPhone, or one the Mac stopped taking: Oby, why, and Connect.
            UnpairedScreen(character: character)
        } else {
            panelled
        }
    }

    private var panelled: some View {
        GeometryReader { geometry in
            let width = min(Tokens.sidebar + 40, geometry.size.width - 56)
            let open = phone.panel != nil
            let shift = min(width, max(0, (open ? width : 0) + drag + edge))
            ZStack(alignment: .leading) {
                SidePanel(width: width, close: close)
                    .frame(width: width)
                    .offset(x: shift - width)
                    .accessibilityHidden(!open)
                    .accessibilityAction(.escape) { close() }
                HomeView(character: character)
                    .frame(width: geometry.size.width)
                    // Home's left edge: a swipe right opens the panel. The system's own edge pan,
                    // which cancels the touch under it, so a row the swipe ends on isn't tapped and
                    // a tap near the edge still lands. Only on Home itself: over a page the edge
                    // is the system's back swipe.
                    .gesture(EdgeSwipe(enabled: !open && phone.homePath.isEmpty) { edge = $0 } ended: { moved in
                        edge = 0
                        if moved > width / 3, phone.homePath.isEmpty { phone.panel = .home }
                    })
                    .overlay {
                        // What the panel pushed aside: a tap brings it back, and so does a drag
                        // back on it. Only here, so the panel's rows keep their own swipes.
                        Tokens.bg.opacity(0.4 * shift / width).ignoresSafeArea()
                            .allowsHitTesting(open)
                            .onTapGesture { close() }
                            .gesture(dragging(width))
                            .accessibilityHidden(true)
                    }
                    .clipShape(Rectangle())
                    .offset(x: shift)
                    .accessibilityHidden(open)
            }
            .animation(reduceMotion ? nil : Tokens.warm, value: open)
        }
        .background(Tokens.bg)
    }

    private func dragging(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drag) { value, state, _ in state = value.translation.width }
            .onEnded { value in
                let open = phone.panel != nil
                let moved = value.predictedEndTranslation.width
                if !open, moved > width / 3 { phone.panel = .home }
                if open, moved < -width / 3 { close() }
            }
    }

    private func close() { phone.panel = nil }
}

/// The panel (Sangam's Sidebar.tsx, on a phone): the icon strip on the far left (Home,
/// Conversations, and your picture at its foot for Settings), the column beside it showing one.
private struct SidePanel: View {
    @Environment(Phone.self) private var phone
    let width: CGFloat
    let close: () -> Void

    var body: some View {
        let section = phone.panel ?? .home
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                strip(.home, "house", "Home", on: section == .home)
                strip(.conversations, "bubble.left.and.bubble.right", "Conversations", on: section == .conversations)
                Spacer()
                Button { open(.settings) } label: { OwnerPicture(name: HomeLine.owner(ofMac: phone.link?.name)) }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Settings")
            }
            .padding(.vertical, 8)
            .frame(width: Tokens.rail)
            .overlay(alignment: .trailing) { Rectangle().fill(Tokens.edge).frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section == .home ? "Home" : "Conversations")
                        .font(Tokens.font(Tokens.textTitle, .semibold)).foregroundStyle(Tokens.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Sangam's panel button, here to put it away again.
                    Button(action: close) {
                        Image(systemName: "sidebar.left").font(Tokens.font(17)).foregroundStyle(Tokens.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide sidebar")
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.top, 4).padding(.bottom, 8)
                switch section {
                case .home: TasksColumn(open: open)
                case .conversations: ConversationsColumn(open: open)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.bg)
    }

    private func strip(_ section: PanelSection, _ icon: String, _ label: String, on: Bool) -> some View {
        Button { phone.panel = section } label: {
            Image(systemName: on ? "\(icon).fill" : icon).font(Tokens.font(17))
                .foregroundStyle(on ? Tokens.ink : Tokens.railIcon)
                .frame(width: 36, height: 36)
                .background(on ? Tokens.active : .clear, in: RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Opens a page over Home and closes the panel, as Sangam's does.
    private func open(_ route: Route) {
        phone.homePath = [route]
        phone.panel = nil
    }
}

/// Home's tasks in the panel (Sangam's side panel grouped by kind): each kind's open tasks and its
/// latest done ones; every task and Archived under them.
private struct TasksColumn: View {
    @Environment(Phone.self) private var phone
    let open: (Route) -> Void

    var body: some View {
        let groups = WorkList.groups(phone.work, by: .type)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    if !phone.loaded && phone.connection == .connecting {
                        RowBones()
                    } else {
                        Text(phone.loaded ? "Nothing here yet. Ask Oby for something and it shows up here." : "Reaching your Mac…")
                            .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 12)
                    }
                }
                ForEach(groups) { group in
                    let folded = phone.panelFolded.contains(group.id)
                    // A kind's name opens its page, as Home's chip does (the owner's addition to
                    // Sangam's design, 2026-10-21); the chevron and the rest of the row fold it.
                    HStack(spacing: 0) {
                        if let kind = group.type {
                            Button { open(.kind(kind)) } label: {
                                Text(group.label).padding(.leading, 12).padding(.trailing, 6).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(group.label)")
                            .accessibilityAddTraits(.isHeader)
                        }
                        Button { withAnimation(Tokens.warm) { phone.panelFolded.formSymmetricDifference([group.id]) } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down").font(Tokens.font(9, .semibold)).rotationEffect(.degrees(folded ? 180 : 0))
                                Spacer(minLength: 4)
                                if folded && group.needs > 0 { Circle().fill(Tokens.needs).frame(width: 6, height: 6) }
                                // A kind's open tasks, as his panel counts them.
                                if group.count > 0 { Text("\(group.count)").monospacedDigit() }
                            }
                            .padding(.trailing, 12).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(folded ? "Show" : "Hide") \(group.label)")
                        .accessibilityValue(group.count > 0 ? "\(group.count) \(group.countLabel)" : "")
                        // The group's header to VoiceOver: its name, or this chevron where it has no page.
                        .accessibilityAddTraits(group.type == nil ? .isHeader : [])
                    }
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label)
                    if !folded {
                        ForEach(WorkList.shown(group, more: false).rows) { item in
                            Button { open(.task(item.id)) } label: { PanelTaskRow(item: item) }.buttonStyle(.plain)
                        }
                    }
                }
                // What needs you with no task on Home, and every task: only when there's some.
                if !phone.loose.isEmpty {
                    Button { open(.inbox) } label: {
                        HStack {
                            Text("Inbox")
                            Spacer()
                            Text("\(phone.loose.count)").monospacedDigit().foregroundStyle(Tokens.needsInk)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 16)
                }
                if !groups.isEmpty {
                    Button("Every task") { open(.all) }.padding(.horizontal, 12).padding(.top, phone.loose.isEmpty ? 16 : 8)
                }
            }
            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item)
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .refreshable { await phone.reload() }
        // Home's foot, as on the Mac: the done tasks that left Home, once there are some.
        if !phone.archived.isEmpty {
            ArchivedFoot(count: phone.archived.count) { open(.archived) }
        }
    }
}

/// Archived and its count at the panel's foot, under a line, 44 tall (the Mac's ArchivedRow,
/// Sangam's `.sidebar-archived`).
private struct ArchivedFoot: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Archived").font(Tokens.font(Tokens.textBase))
                Spacer(minLength: 4)
                Text("\(count)").font(Tokens.font(Tokens.textSm)).monospacedDigit()
            }
            .foregroundStyle(Tokens.label)
            .padding(.horizontal, 12).frame(height: 44)
            .overlay(alignment: .top) { Tokens.line.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .accessibilityLabel("Archived, \(count) task\(count == 1 ? "" : "s")")
    }
}

/// A task in the panel (Sangam's TaskRow): its agent's mark, its title, its one mark.
private struct PanelTaskRow: View {
    let item: WorkList.Item<Job>

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: item.job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.ink.opacity(0.7))
            Text(item.job.heading).font(Tokens.font(Tokens.textBase))
                .foregroundStyle(item.status == .done ? Tokens.doneTitle : Tokens.item).fadeOut()
            WorkMarkView(mark: item.mark).frame(width: 12, height: 12)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.mark.rawValue)
    }
}

/// Your picture until there's a photo (Sangam's OwnerAvatar): your initial on a colour picked from
/// your name, or a person with no name to go by.
struct OwnerPicture: View {
    let name: String?

    var body: some View {
        Group {
            if let name, let initial = name.first {
                Text(String(initial)).font(Tokens.font(11, .semibold)).foregroundStyle(.white.opacity(0.92))
                    .frame(width: 28, height: 28).background(Tokens.avatar(name), in: Circle())
            } else {
                Image(systemName: "person.crop.circle").font(Tokens.font(22)).foregroundStyle(Tokens.railIcon)
                    .frame(width: 28, height: 28)
            }
        }
    }
}

/// A swipe in from the screen's left edge (UIScreenEdgePanGestureRecognizer): how far it has come,
/// then where it ended, a fling counting a little further.
private struct EdgeSwipe: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let recognizer = UIScreenEdgePanGestureRecognizer()
        recognizer.edges = .left
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        let moved = max(0, recognizer.translation(in: recognizer.view).x)
        switch recognizer.state {
        case .began, .changed: changed(moved)
        case .ended: ended(moved + recognizer.velocity(in: recognizer.view).x * 0.15)
        default: ended(0)
        }
    }
}
