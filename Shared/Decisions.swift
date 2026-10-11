import Foundation

// Decisions as Claude Code shows them (#138): one card (Shared/DecisionCard.swift) for a job's
// question, a plan to approve, an inbox item, a permission prompt and the brain's question, on the
// iPhone, the Mac and the Watch. The recommended option comes first, then the others (at most 3 in
// all), then a line for the user's own words. The permission keys are the runner's (#134,
// docs/runner-api.md): every one is new, so every one is optional, and an older runner sends none
// of them. No SwiftUI here: the Watch's complications read these too.

/// How freely a job's agent works (`Job.mode`).
nonisolated enum RunnerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, acceptEdits, plan, bypass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .bypass: "Bypass"
        }
    }

    /// What the agent may do in it, in one line.
    var help: String {
        switch self {
        case .ask: "Asks before it edits a file or runs a command"
        case .acceptEdits: "Edits files without asking; asks before commands"
        case .plan: "Plans first, and works once you approve the plan"
        case .bypass: "Asks nothing"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .bypass: "bolt"
        }
    }

    /// The mode the runner named, or nil for none, or one this app doesn't know yet.
    init?(_ raw: String?) {
        guard let raw, let mode = Self(rawValue: raw) else { return nil }
        self = mode
    }
}

/// What a job's agent waits for the user's OK on (`Job.permission`): the job stays running, its
/// step "Waiting for your OK".
nonisolated struct RunnerPermission: Codable, Equatable, Sendable {
    /// What `POST /v1/jobs/{id}/permission` answers.
    enum Decision: String, Codable, Sendable { case allow, always, deny }

    var id: String
    /// "Bash", "Edit"…
    var tool: String?
    /// "Run swift test"
    var title: String
    /// The command or the file.
    var detail: String?
    /// What Always allow saves, like "Bash(swift test:*)".
    var rule: String?
    /// Always allow, spelled out: "Yes, and don't ask again for swift test in deskree-inc/oby".
    var always: String?
}

/// A saved permission rule (`GET /v1/permissions/rules`).
nonisolated struct RunnerRule: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var rule: String
    var repo: String?
    /// "allow" or "deny".
    var decision: String
    var created: Date?
}

#if os(macOS)
/// What a runner's job carries that Engine's Job, which the Mac reads it into, doesn't read yet:
/// its mode, the permission it waits on, and its question with the recommended option and the
/// plan. Read from the same JSON; never fails the job (#134 brings these to Engine).
nonisolated struct RunnerJobExtras: Decodable, Equatable, Sendable {
    var id: String
    var mode: String?
    var permission: RunnerPermission?
    var question: Question?

    private enum Keys: String, CodingKey { case id, mode, permission, question }

    init(id: String, mode: String? = nil, permission: RunnerPermission? = nil, question: Question? = nil) {
        self.id = id
        self.mode = mode
        self.permission = permission
        self.question = question
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        id = try keys.decode(String.self, forKey: .id)
        mode = try? keys.decodeIfPresent(String.self, forKey: .mode)
        permission = try? keys.decodeIfPresent(RunnerPermission.self, forKey: .permission)
        question = try? keys.decodeIfPresent(Question.self, forKey: .question)
    }

    /// Each job's, by id; a list that can't be read gives none.
    static func of(_ data: Data) -> [String: RunnerJobExtras] {
        struct Lossy: Decodable {
            var extras: RunnerJobExtras?
            init(from decoder: any Decoder) throws { extras = try? RunnerJobExtras(from: decoder) }
        }
        let list = (try? Runner.decoder.decode([Lossy].self, from: data))?.compactMap(\.extras) ?? []
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }
}
#endif

/// One answer on a decision card.
nonisolated struct CardOption: Equatable, Sendable {
    enum Role: Sendable { case plain, destructive }

    /// What the button says.
    var label: String
    /// What choosing it sends: the option itself, or a permission's decision.
    var answer: String
    /// A line under it, like the rule Always allow saves.
    var detail: String? = nil
    var recommended = false
    var role: Role = .plain

    /// A card offers at most this many; the user's own words take the rest.
    static let most = 3
    /// What the user's own words do on a permission card.
    static let denyWords = "Your words go with a Deny, for the agent."

    /// The recommended one first, marked, then the others in their order, at most `most` in all.
    /// An index out of range recommends nothing.
    static func of(_ options: [String], recommended: Int? = nil) -> [CardOption] {
        var list = options.enumerated().map { CardOption(label: $1, answer: $1, recommended: $0 == recommended) }
        if let index = list.firstIndex(where: \.recommended) { list.insert(list.remove(at: index), at: 0) }
        return Array(list.prefix(most))
    }

    /// The same, with the recommended one named rather than numbered (an inbox item's options
    /// against its job's question).
    static func of(_ options: [String], recommending label: String?) -> [CardOption] {
        of(options, recommended: label.flatMap { options.firstIndex(of: $0) })
    }

    /// Allow, Always allow with the rule spelled out (when the runner can save one), and Deny.
    static func permission(_ permission: RunnerPermission) -> [CardOption] {
        var list = [CardOption(label: "Allow", answer: RunnerPermission.Decision.allow.rawValue)]
        if let always = permission.always ?? permission.rule.map({ "Don't ask again for \($0)" }) {
            list.append(CardOption(label: "Always allow", answer: RunnerPermission.Decision.always.rawValue, detail: always))
        }
        list.append(CardOption(label: "Deny", answer: RunnerPermission.Decision.deny.rawValue, role: .destructive))
        return list
    }
}

extension CardOption {
    /// An inbox item's answers (`kind` as the runner names it): a question's with its job's
    /// recommended one first, a permission's with the rule Always allow saves and Deny in red.
    /// Oby's own recommendation (`words`, #65) comes before the job question's, and its why goes
    /// under the option it recommends.
    static func inbox(_ options: [String], kind: String, question: Question? = nil, permission: RunnerPermission? = nil,
                      words: InboxWords? = nil) -> [CardOption] {
        let ours = words?.recommended.flatMap { options.indices.contains($0) ? $0 : nil }
        var list = ours.map { of(options, recommended: $0) } ?? of(options, recommending: kind == "question" ? question?.recommendedOption : nil)
        for index in list.indices {
            if kind == "permission", list[index].label == "Always allow" {
                list[index].detail = permission?.always ?? permission?.rule.map { "Don't ask again for \($0)" }
            }
            if kind == "permission", list[index].label == "Deny" { list[index].role = .destructive }
            if list[index].recommended, let why = InboxWords.plain(words?.why) {
                list[index].detail = [list[index].detail, why].compactMap(\.self).joined(separator: "\n")
            }
        }
        return list
    }
}

/// Oby's plain words for an inbox item (#65), from newer runners: a headline of at most 8 words,
/// what happened in a sentence or two, the option it recommends (an index, or nil) and why. Every
/// key is optional, and one that can't be read counts as missing: the card then shows the item
/// as before.
nonisolated struct InboxWords: Decodable, Equatable, Sendable {
    var headline: String?
    var happened: String?
    var recommended: Int?
    var why: String?

    private enum Keys: String, CodingKey { case headline, happened, recommended, why }

    init(headline: String? = nil, happened: String? = nil, recommended: Int? = nil, why: String? = nil) {
        self.headline = headline
        self.happened = happened
        self.recommended = recommended
        self.why = why
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        headline = try? keys.decodeIfPresent(String.self, forKey: .headline)
        happened = try? keys.decodeIfPresent(String.self, forKey: .happened)
        recommended = try? keys.decodeIfPresent(Int.self, forKey: .recommended)
        why = try? keys.decodeIfPresent(String.self, forKey: .why)
    }

    /// The card's title: the headline, else the item's text, as before.
    func title(_ text: String) -> String { Self.plain(headline) ?? text }

    /// What happened, under the title, or nil.
    var body: String? { Self.plain(happened) }

    /// The item's own text, behind Details once the headline stands in for it; else nil (it's the title).
    func details(_ text: String) -> String? { Self.plain(headline) == nil ? nil : Self.plain(text) }

    /// The words, or nil when there are none.
    static func plain(_ words: String?) -> String? {
        guard let words = words?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        return words
    }

    #if os(macOS)
    /// Each runner item's words, by item id, from `GET /v1/inbox`: the Mac reads the items into
    /// Engine's InboxItem, which doesn't have them. A list that can't be read gives none.
    static func of(_ data: Data) -> [String: InboxWords] {
        struct Lossy: Decodable {
            var id: String?
            var words: InboxWords?
            private enum Keys: String, CodingKey { case id }
            init(from decoder: any Decoder) throws {
                id = try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .id)
                words = try? InboxWords(from: decoder)
            }
        }
        let list = (try? Runner.decoder.decode([Lossy].self, from: data)) ?? []
        return Dictionary(list.compactMap { item in item.id.flatMap { id in item.words.map { (id, $0) } } }, uniquingKeysWith: { $1 })
    }
    #endif
}

extension Question {
    /// The option the asker recommends, or nil.
    nonisolated var recommendedOption: String? {
        recommended.flatMap { options.indices.contains($0) ? options[$0] : nil }
    }

    nonisolated var cardOptions: [CardOption] { CardOption.of(options, recommended: recommended) }
}

/// A plan in markdown, split into what the card draws: headings, list items, code and paragraphs
/// (the card draws each one's inline markdown).
nonisolated enum PlanBlock: Equatable, Sendable {
    case heading(String)
    /// The marker ("•", "1.") and the item.
    case item(String, String)
    case code(String)
    case text(String)

    static func blocks(_ markdown: String) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var code: [String]?
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(String(raw)); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
                flush()
                blocks.append(.item("•", line.dropFirst(2).trimmingCharacters(in: .whitespaces)))
            } else if let match = line.firstMatch(of: /^(\d{1,3})[.)] (.*)$/) {
                flush()
                blocks.append(.item("\(match.1).", String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
