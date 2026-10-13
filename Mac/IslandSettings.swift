import SwiftUI

/// The quick settings surface in the notch. It deliberately uses the same rows and controls as
/// the full Mac and iPhone settings, with the full window one tap away for anything uncommon.
struct IslandSettings: View {
    let model: IslandModel
    @AppStorage(Speaker.setting) private var speaks = true
    @AppStorage(MacChecks.appleSetting) private var buildAgents = true

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Accounts") {
                    AccountSections("On this Mac", items: desk.accounts.accounts, id: \.account.id,
                                    usage: \.usage, place: "on this Mac") { state in
                        UsageCard(snapshot: state.usage)
                        ReserveSwitch(snapshot: state.usage) { lift in _ = desk.liftReserve(state.account.id, lift) }
                    }
                    if feed.runner != nil {
                        AccountSections("On \(feed.name)", items: feed.accounts, id: \.account.id,
                                        usage: \.usage, place: "on \(feed.name)") { state in
                            UsageCard(snapshot: state.usage)
                            ReserveSwitch(snapshot: state.usage) { lift in
                                guard let runner = feed.runner else { throw RunnerError(message: "Set the runner's URL first.") }
                                _ = try await runner.liftReserve(state.account.id, lift)
                            }
                        }
                    }
                }

                section("The runner") {
                    LabeledContent("Status", value: feed.connection.status(host: feed.name))
                    LabeledContent("Version", value: feed.version ?? "Unknown")
                    Toggle("Build and test agents' work on this Mac", isOn: $buildAgents)
                }

                PermissionsSection(runner: feed.runner, defaultMode: feed.defaultMode, setDefault: feed.setDefaultMode)
                VoiceSection(speaks: $speaks,
                             footer: "Hold fn to talk. Oby replies aloud when this is on.")
                NotificationsSection()

                Button { SettingsSelection.open(.general) } label: {
                    Label("More Settings…", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 4)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 390)
        .accessibilityLabel("Quick Settings")
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            content()
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
