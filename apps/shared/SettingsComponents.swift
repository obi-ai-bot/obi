#if os(iOS) || os(macOS)
import SwiftUI

// Sangam's Settings building blocks (design/app/src/renderer/src/app.css `.set-*`, SettingsView.tsx), on
// Tokens: each setting a row on a card, its name on the left and its control on the right, cards in
// titled groups with a note under them. The Mac's Settings pages are made of these, and the iPhone's
// can be.

extension EnvironmentValues {
    /// Settings' sections both apps share (SettingsSections.swift, PermissionsSection.swift) draw as
    /// Sangam's cards instead of a grouped form's sections: the Mac's Settings pages set it.
    @Entry var settingsCards = false
}

/// A titled group of rows on a card, a note under it (`.set-group`, `.set-head`, `.set-card`, `.set-foot`).
/// The rows get a divider between them, never above the first. What went wrong shows under the card
/// in `danger` (`.set-problem`), over the note.
struct SetGroup<Content: View>: View {
    var title: String?
    var footer: String?
    var problem: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, problem: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.problem = problem
        self.content = content()
    }

    /// Room under a group, before the next.
    static var gap: CGFloat { 28 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.item)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // The 1-point edge is outside the rows, as CSS's border is.
            .padding(1)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tokens.surfaceEdge))
            if let problem {
                SetAbout(problem, color: Tokens.danger).padding(.horizontal, 16).padding(.top, 8)
            }
            if let footer {
                SetAbout(footer).padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .padding(.bottom, Self.gap)
    }
}

/// One setting (`.set-row`): its name, and a line on it, on the left; its control on the right. At
/// least 56 tall.
struct SetRow<Label: View, Control: View>: View {
    var about: String?
    /// The control at the row's top instead of its middle, beside a tall label (`.set-control-top`).
    var controlOnTop = false
    @ViewBuilder var label: Label
    @ViewBuilder var control: Control

    init(about: String? = nil, controlOnTop: Bool = false, @ViewBuilder label: () -> Label, @ViewBuilder control: () -> Control) {
        self.about = about
        self.controlOnTop = controlOnTop
        self.label = label()
        self.control = control()
    }

    var body: some View {
        HStack(alignment: controlOnTop ? .top : .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                label.font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink)
                if let about { SetAbout(about) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { control }
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }
}

extension SetRow where Label == Text {
    init(_ title: String, about: String? = nil, controlOnTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.init(about: about, controlOnTop: controlOnTop, label: { Text(title) }, control: control)
    }
}

extension SetRow where Label == Text, Control == EmptyView {
    /// A row with nothing to change: a name, or a muted "None yet" with `quiet`.
    init(_ title: String, about: String? = nil, quiet: Bool = false) {
        self.init(about: about, label: { Text(title).foregroundStyle(quiet ? Tokens.muted : Tokens.ink) }, control: { EmptyView() })
    }
}

extension SetRow where Control == EmptyView {
    init(about: String? = nil, @ViewBuilder label: () -> Label) {
        self.init(about: about, label: label, control: { EmptyView() })
    }
}

/// A line under a row's name, or a note under a card (`.set-about`, `.set-foot`): 12, muted, a loose
/// line height (1.45).
struct SetAbout: View {
    var text: String
    var color = Tokens.muted

    init(_ text: String, color: Color = Tokens.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(Tokens.font(Tokens.textSm)).foregroundStyle(color)
            .lineSpacing(Tokens.textSm * 0.45 - 2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A read-only value on a row's right (`.set-value`); "Connected" gets its green dot (`.set-dot`). It
/// can be selected and copied, like everything on a Settings page.
struct SetValue: View {
    var text: String
    var connected = false

    init(_ text: String, connected: Bool = false) {
        self.text = text
        self.connected = connected
    }

    /// The green of "Connected".
    static let dot = Tokens.done

    var body: some View {
        HStack(spacing: 6) {
            if connected { Circle().fill(Self.dot).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(text).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).textSelection(.enabled)
        }
    }
}

/// A name in code (`.tok-code`): a rule, a secret's name. Coral SF Mono 13 on white 8%, 4 round.
struct SetCode: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Tokens.mono(Tokens.textMd)).foregroundStyle(Tokens.code)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Tokens.pill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .textSelection(.enabled)
    }
}

/// The on/off switch (`.set-switch`): 32 × 18, white 14% off and ink on, a 14-point knob in `text`
/// (`bg` when on), 200 ms warm; never the system's green toggle. The row carries the name, so the
/// toggle's own label is only what VoiceOver reads.
struct SetSwitch: ToggleStyle {
    static func track(on: Bool) -> Color { on ? Tokens.ink : Tokens.track }
    static func knob(on: Bool) -> Color { on ? Tokens.bg : Tokens.text }
    /// The knob's left edge.
    static func knobX(on: Bool) -> CGFloat { on ? 16 : 2 }
    static let motion = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    func makeBody(configuration: Configuration) -> some View {
        Knob(configuration: configuration)
    }

    /// A plain button underneath, so Full Keyboard Access focuses it and Space toggles it.
    struct Knob: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var still

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(SetSwitch.track(on: on))
                    .frame(width: 32, height: 18)
                    .overlay(alignment: .leading) {
                        Circle().fill(SetSwitch.knob(on: on)).frame(width: 14, height: 14).offset(x: SetSwitch.knobX(on: on))
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
                .opacity(enabled ? 1 : 0.3)
                .animation(still ? nil : SetSwitch.motion, value: on)
                .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// Lets `SetSelect` tell a missing value (nil) from one its options don't hold.
protocol OptionalProtocol { var isNone: Bool { get } }
extension Optional: OptionalProtocol {
    var isNone: Bool { if case .none = self { true } else { false } }
}

extension ToggleStyle where Self == SetSwitch {
    static var set: SetSwitch { SetSwitch() }
}

/// A Settings button (`.set-button`): 32 tall, 8 round, `chipHover` on a 1-point line, lighter
/// hovered; `danger` words for one that takes something away (Remove, Forget, Disconnect: give it
/// `role: .destructive`), 30% when it can't be pressed.
struct SetButtonStyle: ButtonStyle {
    static func text(destructive: Bool) -> Color { destructive ? Tokens.danger : Tokens.ink }
    static func fill(hovered: Bool) -> Color { hovered ? Color(hex: 0x29292C) : Tokens.chipHover }
    static func edge(hovered: Bool) -> Color { hovered ? Tokens.lineStrong : Tokens.line }
    static func opacity(enabled: Bool) -> Double { enabled ? 1 : 0.3 }

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    private struct Pressable: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let hot = enabled && (hovering || configuration.isPressed)
            let shape = RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous)
            configuration.label
                .font(Tokens.font(Tokens.textBase)).lineLimit(1)
                .foregroundStyle(SetButtonStyle.text(destructive: configuration.role == .destructive))
                .padding(.horizontal, 14).frame(height: 32)
                .background(SetButtonStyle.fill(hovered: hot), in: shape)
                .overlay(shape.strokeBorder(SetButtonStyle.edge(hovered: hot)))
                .contentShape(shape)
                .opacity(SetButtonStyle.opacity(enabled: enabled))
                .onHover { hovering = $0 }
                .animation(Tokens.fade, value: hot)
        }
    }
}

extension ButtonStyle where Self == SetButtonStyle {
    static var set: SetButtonStyle { SetButtonStyle() }
}

/// A field's frame (`.set-field`, and the pop-up's): 32 tall, 8 round, `field` fill, a 1-point
/// line that lights up hovered or focused.
private struct FieldFrame: ViewModifier {
    var hot: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous)
        content
            .frame(height: 32)
            .background(Tokens.field, in: shape)
            .overlay(shape.strokeBorder(SetField.edge(hot: hot)))
            .animation(Tokens.fade, value: hot)
    }
}

/// A pop-up menu (`.set-select`): the chosen option's name and a small chevron in a field's frame;
/// the menu itself is the system's, with a check by the chosen one.
struct SetSelect<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]
    @State private var hovering = false

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    /// What the pop-up shows for `value`: its option's name, the value itself when no option has it
    /// (a model a plan dropped), or a dash while there's none yet.
    static func name(of value: Value, in options: [(Value, String)]) -> String {
        if let name = options.first(where: { $0.0 == value })?.1 { return name }
        if let optional = value as? any OptionalProtocol, optional.isNone { return "—" }
        return "\(value)"
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 10) {
                Text(Self.name(of: selection, in: options)).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.muted)
            }
            .padding(.leading, 14).padding(.trailing, 12)
            .modifier(FieldFrame(hot: hovering))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(Self.name(of: selection, in: options))
    }
}

/// A segmented choice (`.set-segmented`): `chip` on a 1-point line, 26-point segments, the one
/// that's on in white 12%.
struct SetSegmented<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    static func fill(on: Bool) -> Color { on ? Tokens.bubble : .clear }
    static func text(on: Bool) -> Color { on ? Tokens.ink : Tokens.text }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, name in
                let on = value == selection
                Button { selection = value } label: {
                    Text(name).font(Tokens.font(Tokens.textMd)).foregroundStyle(Self.text(on: on))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Self.fill(on: on), in: RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3) // 2 around the segments, and the 1-point line, as CSS draws it
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous).strokeBorder(Tokens.line))
        .animation(Tokens.fade, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A text field (`.set-field`): 220 wide in a field's frame, the prompt muted; `secret` hides what's
/// typed.
struct SetField: View {
    var title: String
    @Binding var text: String
    var prompt: String
    var secret = false
    var width = SetField.width
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, prompt: String, secret: Bool = false, width: CGFloat = SetField.width) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.secret = secret
        self.width = width
    }

    static let width: CGFloat = 220
    static func edge(hot: Bool) -> Color { hot ? Tokens.fieldEdgeOn : Tokens.line }

    var body: some View {
        Group {
            let prompt = Text(prompt).foregroundStyle(Tokens.muted)
            if secret {
                SecureField(title, text: $text, prompt: prompt)
            } else {
                TextField(title, text: $text, prompt: prompt).autocorrectionDisabled()
            }
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink)
        .focused($focused)
        .padding(.horizontal, 14)
        .frame(width: width)
        .modifier(FieldFrame(hot: hovering || focused))
        .onHover { hovering = $0 }
    }
}

/// A usage meter (`.set-meter`): a 4-point bar, 2 round, at most 280 wide, white 8% under a `text`
/// fill, `full` past 80% and `over` past 90%.
struct SetMeter: View {
    /// How much is used, 0 to 100.
    var used: Double

    static let maxWidth: CGFloat = 280
    static func fill(used: Double) -> Color { used > 90 ? Tokens.over : used > 80 ? Tokens.full : Tokens.text }
    static func fraction(used: Double) -> Double { min(max(used, 0), 100) / 100 }

    var body: some View {
        Capsule().fill(Tokens.meter)
            .overlay(alignment: .leading) {
                GeometryReader { box in
                    Capsule().fill(Self.fill(used: used)).frame(width: box.size.width * Self.fraction(used: used))
                }
            }
            .clipShape(Capsule())
            .frame(height: 4)
            .frame(maxWidth: Self.maxWidth)
            .accessibilityElement()
            .accessibilityLabel("\(Int(used.rounded()))% used")
    }
}
#endif
