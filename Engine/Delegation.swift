import Foundation

/// A short-lived, read-only investigation requested by the conversation brain.
nonisolated struct Delegation: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable { case researcher, reviewer, verifier }
    enum Status: String, Codable, Sendable { case queued, running, complete, partial, failed, stopped }

    var id: String
    var turn: String
    var role: Role
    var goal: String
    var context: String
    var repo: String?
    var ref: String?
    var commit: String?
    var web: Bool
    var agent: String
    var account: String
    var model: String
    var effort: String
    var status: Status = .queued
    var step = ""
    var created = Date.now
    var started: Date?
    var finished: Date?
    var result: DelegateResult?
    var error: String?

    static let mostRunning = 6
    static let maximumResultBytes = 16 * 1024
}

nonisolated struct DelegateResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case complete, partial, failed }
    struct Evidence: Codable, Equatable, Sendable { var link: String; var quote: String }
    struct Finding: Codable, Equatable, Sendable { var claim: String; var evidence: [Evidence]; var confidence: String }

    var outcome: Outcome
    var summary: String
    var findings: [Finding]
    var openQuestions: [String]
    var verdict: String?

    func problems(for role: Delegation.Role) -> [String] {
        var errors: [String] = []
        if summary.count > 1500 { errors.append("summary exceeds 1,500 characters") }
        if findings.count > 20 { errors.append("findings exceeds 20") }
        if openQuestions.count > 10 { errors.append("openQuestions exceeds 10") }
        if findings.contains(where: { $0.claim.isEmpty || !["high", "medium", "low"].contains($0.confidence) || $0.evidence.isEmpty }) {
            errors.append("each finding needs a claim, evidence and valid confidence")
        }
        if findings.flatMap(\.evidence).contains(where: {
            $0.quote.count > 300 || URLComponents(string: $0.link)?.scheme?.lowercased() != "https" || URLComponents(string: $0.link)?.host == nil
        }) {
            errors.append("evidence needs an HTTPS link and a quote of at most 300 characters")
        }
        if verdict != nil && role == .researcher { errors.append("only reviewers and verifiers return a verdict") }
        if let verdict, !["holds", "concerns", "fails"].contains(verdict) { errors.append("verdict must be holds, concerns or fails") }
        return errors
    }
}
