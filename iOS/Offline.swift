import Foundation

struct OfflineInboxAnswer: Codable, Equatable, Sendable {
    var id: String
    var answer: String?
    var done: Bool?
    var later: Date?
}

struct OfflineMessage: Codable, Equatable, Sendable {
    var id: String
    var said: String
    var question: String?
    var option: String?
    var voice: Bool
}
