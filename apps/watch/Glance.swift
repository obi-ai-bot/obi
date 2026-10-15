import Foundation

/// What the complications and the Smart Stack show: how many jobs need you, how many are working
/// and how many wait their turn (#238), as the iPhone last sent them. Compiled into the watch app,
/// which saves it to the app group whenever the job list arrives, and into the widget extension,
/// which reads it.
nonisolated struct Glance: Codable, Equatable {
    var needs: Int
    /// Running, or getting ready to: jobs waiting their turn aren't working.
    var working: Int
    /// Queued behind something; nil from a glance saved before #238.
    var waiting: Int? = nil
    /// The first job that needs you, for the rectangular complication.
    var top: String?

    static let kind = "com.deskree.oby.needs-you"
    static let empty = Glance(needs: 0, working: 0)
    /// What the watch face's gallery shows.
    static let sample = Glance(needs: 1, working: 2, top: "Fix the login redirect")

    /// "1 needs you", "2 working", "14 waiting", or "All quiet", as Home says it.
    var line: String {
        if needs > 0 { return needs == 1 ? "1 needs you" : "\(needs) need you" }
        if working > 0 { return "\(working) working" }
        return Summary.waitingLine(waiting ?? 0) ?? "All quiet"
    }

    private static let key = "glance"
    /// The app group both targets share; its name is in each Info.plist (`ObyAppGroup`).
    static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "ObyAppGroup") as? String).flatMap(UserDefaults.init(suiteName:))
    }

    static var stored: Glance {
        guard let data = defaults?.data(forKey: key), let glance = try? JSONDecoder().decode(Glance.self, from: data) else { return .empty }
        return glance
    }

    /// Saves it, and says whether it changed: the complications reload only when they'd look
    /// different, since watchOS limits how often a widget may reload.
    static func save(_ glance: Glance) -> Bool {
        guard let defaults, glance != stored, let data = try? JSONEncoder().encode(glance) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
