import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Why the Mac can't be reached, in the same words on every screen (docs/oby-ux.md "Offline, and
/// when the Mac sleeps", rows 17-18; docs/onboarding.md "Errors and recovery"). Nothing while it's
/// live or still connecting.
nonisolated enum ReachNotice: Equatable, Sendable {
    /// The Mac said it was going to sleep. Nothing says so yet: obid or the Mac has to tell the
    /// iPhone first (`NSWorkspace.willSleepNotification`, onboarding.md); until then it reads as
    /// unreachable.
    case asleep(since: Date?)
    case unreachable(lastSeen: Date?)
    case noInternet(lastSeen: Date?)
    /// The gateway refused this iPhone's token: revoked on the Mac.
    case removed
    /// The gateway refused it after its 30 days were up (docs/runner-api.md, "Redeeming").
    case expired

    /// What waits on the iPhone while the Mac can't be reached.
    static let waiting = "Sends when your Mac is back"

    /// `status`: the HTTP status of the last refusal, if the Mac answered at all; `paired`: the
    /// iPhone reaches a Mac's gateway with a device token (a 401 then means it was removed, or that
    /// its pairing ended: `expires`, when it does).
    static func of(_ connection: RunnerConnection, online: Bool, status: Int?, paired: Bool, lastSeen: Date?,
                   expires: Date? = nil, now: Date = .now) -> ReachNotice? {
        guard case .offline = connection else { return nil }
        if !online { return .noInternet(lastSeen: lastSeen) }
        if paired, status == 401 { return (expires.map { $0 <= now } ?? false) ? .expired : .removed }
        return .unreachable(lastSeen: lastSeen)
    }

    var title: String {
        switch self {
        case .asleep: "Your Mac is asleep"
        case .unreachable: "Can't reach your Mac"
        case .noInternet: "No internet on this iPhone"
        case .removed: "This iPhone was removed from your Mac"
        case .expired: "Pairing with your Mac ended"
        }
    }

    var detail: String {
        switch self {
        case .asleep(let since):
            (since.map { "Since \(Self.when($0)). " } ?? "") + "Oby picks up when it wakes; what you send waits here until then."
        case .unreachable(let seen):
            (seen.map { "Last seen \(Self.when($0)). " } ?? "") + "Check it's on and online."
        case .noInternet(let seen):
            seen.map { "Showing what Oby knew at \(Self.when($0))." } ?? "Showing what Oby knew."
        case .removed:
            "Scan the code in Oby on your Mac to connect again."
        case .expired:
            "It lasts 30 days. Scan the code in Oby on your Mac to connect again."
        }
    }

    /// "9:41 AM" today, "Oct 17, 9:41 AM" before.
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }
}

#if canImport(SwiftUI)
/// The notice as one line where you are: the title in `ink`, why in `muted`, an orange dot ahead.
struct ReachLine: View {
    let notice: ReachNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(notice == .removed || notice == .expired ? Tokens.danger : Tokens.needs).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            Text("\(Text(notice.title).foregroundStyle(Tokens.ink))  \(Text(notice.detail).foregroundStyle(Tokens.muted))")
                .font(Tokens.font(Tokens.textSm))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.gutter).padding(.vertical, 8)
        .background(Tokens.bg)
        .accessibilityElement(children: .combine)
    }
}
#endif
