import SwiftUI

/// What the side panel shows (Sangam's Sidebar.tsx): its icon strip picks Home's tasks or the
/// conversations; your picture at its foot opens Settings.
enum PanelSection: Hashable { case home, conversations }

/// Oby on iPhone with no tab bar (the owner's call, 2026-10-18, as Sangam's design has none): Home
/// and everything opened over it in one stack, and Sangam's side panel. It opens from the left and
/// pushes the view over: the panel button at Home's top left, or a swipe from the screen's left
/// edge on Home; a tap on what it pushed aside, or a swipe back, closes it.
struct PhoneRoot: View {
    @Environment(Phone.self) private var phone
    let character: ObyCharacter
    /// How far a drag has moved the panel from where it rests.
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        if phone.needsPairing {
            // A fresh iPhone, or one the Mac stopped taking: Connect first, the line saying why.
            VStack(spacing: 0) {
                if let notice = phone.notice { ReachLine(notice: notice) }
                NavigationStack { ConnectScreen() }
            }
            .background(Tokens.bg)
        } else {
            panelled
        }
    }

    private var panelled: some View {
        GeometryReader { geometry in
            let width = min(Tokens.sidebar + 40, geometry.size.width - 56)
            let open = phone.panel != nil
            let shift = min(width, max(0, (open ? width : 0) + drag))
            ZStack(alignment: .leading) {
                SidePanel(width: width)
                    .frame(width: width)
                    .offset(x: shift - width)
                    .accessibilityHidden(!open)
                HomeView(character: character)
                    .frame(width: geometry.size.width)
                    .overlay {
                        // What the panel pushed aside: a tap brings it back.
                        Tokens.bg.opacity(0.4 * shift / width).ignoresSafeArea()
                            .allowsHitTesting(open)
                            .onTapGesture { close() }
                            .accessibilityHidden(true)
                    }
                    .clipShape(Rectangle())
                    .offset(x: shift)
                    .accessibilityHidden(open)
                // Home's left edge: a swipe right opens the panel. On a page over Home the edge is
                // the system's back swipe.
                if !open, phone.homePath.isEmpty {
                    Color.clear.frame(width: 20).contentShape(Rectangle()).gesture(dragging(width))
                }
            }
            .gesture(open ? dragging(width) : nil)
            .animation(Tokens.warm, value: open)
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
                Text(section == .home ? "Home" : "Conversations")
                    .font(Tokens.font(Tokens.textTitle, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
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
                    Text(phone.loaded ? "Nothing yet. Ask Oby for something on Home." : "Reaching your Mac…")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.horizontal, 12)
                }
                ForEach(groups) { group in
                    HStack {
                        Text(group.label).accessibilityAddTraits(.isHeader)
                        Spacer()
                        // A kind's open tasks, as his panel counts them.
                        if group.count > 0 { Text("\(group.count)").monospacedDigit() }
                    }
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label)
                    .padding(.horizontal, 12).frame(height: 26).padding(.top, 8)
                    ForEach(WorkList.shown(group, more: false).rows) { item in
                        Button { open(.task(item.id)) } label: { PanelTaskRow(item: item) }.buttonStyle(.plain)
                    }
                }
                Button("Every task") { open(.all) }.padding(.horizontal, 12).padding(.top, 16)
                Button { open(.archived) } label: {
                    HStack {
                        Text("Archived")
                        Spacer()
                        if !phone.archived.isEmpty { Text("\(phone.archived.count)").monospacedDigit().foregroundStyle(Tokens.label) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item)
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .refreshable { await phone.reload() }
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
