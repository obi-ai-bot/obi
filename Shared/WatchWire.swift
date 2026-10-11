import Foundation

// What the iPhone and the Apple Watch say to each other over WatchConnectivity
// (iOS/WatchRelay.swift and Watch/Watch.swift). The watch can't reach the tailnet, so the phone
// keeps the jobs on it and carries out what it asks; out of the phone's reach, a paired watch
// calls the runner's Watch API through a Cloudflare Tunnel instead (Watch/WatchLink.swift). Messages are dictionaries of property-list
// values; the typed parts travel as JSON made with Runner.encoder.
#if os(iOS) || os(watchOS)
/// The jobs the phone keeps on the watch, as the application context: the ones the watch shows,
/// trimmed to what WatchConnectivity carries (iOS/WatchRelay.swift).
nonisolated struct WatchContext: Codable, Equatable, Sendable {
    var jobs: [Job]
    var accounts: [Account]
    var host: String
    var sentAt: Date
}

/// The brain's answer as the phone relays it. PlanResult only decodes, so this is its mirror.
nonisolated struct RelayedPlan: Codable, Equatable, Sendable {
    var drafts: [Draft] = []
    var question: Question?
    var questionSaid: String?
    var reply: String?

    init(_ result: PlanResult) {
        switch result {
        case .plan(let drafts): self.drafts = drafts
        case .question(let said, let question): questionSaid = said; self.question = question
        case .reply(let text): reply = text
        case .none: break
        }
    }
}

/// The keys of the messages, and what each kind carries.
///
/// From the watch, answered in the reply:
/// - `refresh`: nothing; answered with `context`.
/// - `voice`: `audio` (an AAC recording) and `request`; answered with `text` (what was said),
///   then the plan arrives as a `planned` message.
/// - `voiceStart`: `request`, `sampleRate` (must be 16000); opens a live transcription each time the
///   watch's mic is tapped to listen (answered with `ok`).
/// - `voiceChunk`: `request`, zero-based `sequence`, `audio` (mono signed little-endian Int16 PCM at 16 kHz);
///   acknowledged with `ok`. Each chunk is <= `chunkLimit`; chunks are sent in order, each after
///   the previous one's reply. The phone drops a stream that goes 30 seconds without a chunk.
/// - `voiceEnd`: `request`, `sequence` (total chunks); sent when the watch stops listening. Finishes
///   the text, answered with `text` (empty when nothing was said). Nothing is planned: the watch keeps
///   the words as a draft, and sends them as a `plan` when the user taps Send.
/// - `voiceCancel`: `request`; drops live audio or a pending plan, answered with `ok`.
/// - `plan`: `said` and `request`, with `question` and `option` to answer the brain; answered
///   with `ok`, then the plan arrives as a `planned` message.
/// - `dispatch`: `draft`; answered with `job`.
/// - `tell`: `job` (its id) and `text`; answered with `job`.
/// - `stop`: `job` (its id); answered with `job`.
/// - `dismiss`: `job` (its id); answered with `job`.
/// - `publishAction`: `job` (its id); answered with `action`.
/// - `publish`: `job` (its id) and `action`; answered with `ok`, then a `published` message.
///
/// From the phone, as a message of its own (queued when the watch app isn't up):
/// - `transcript`: `request`, `text` (the whole current transcript, replacing the last one).
///   Ephemeral: never queued for delivery after listening stops.
/// - `planned`: `request` and `said`, with `plan` (a RelayedPlan) or `error`.
/// - `published`: `job` (its id), with `url`, `pending` (Face ID waits on the phone) or `error`.
///
/// From the phone, answered in the reply (iOS/WatchPairing.swift):
/// - `pairKey`: nothing; answered with `publicKey` (the watch's Secure Enclave key, X9.63) and `name`.
/// - `paired`: `watch` (its id on the runner), `url` (the Watch API's address), `clientId` and
///   `clientSecret` (the Cloudflare Access service token); answered with `ok`.
/// - `unpaired`: `watch`; the watch forgets its pairing if it's that one; answered with `ok`.
///
/// Any reply may carry `error` instead of what was asked for.
nonisolated enum WatchWire {
    enum Kind: String { case refresh, voice, voiceStart, voiceChunk, voiceEnd, voiceCancel, transcript, plan, dispatch, tell, stop, dismiss, publishAction, publish, planned, published, pairKey, paired, unpaired }

    static let kind = "kind"
    static let ok = "ok"
    static let error = "error"
    static let context = "context"
    static let request = "request"
    static let audio = "audio"
    static let sequence = "sequence"
    static let sampleRate = "sampleRate"
    static let text = "text"
    static let said = "said"
    static let question = "question"
    static let option = "option"
    static let draft = "draft"
    static let job = "job"
    static let action = "action"
    static let url = "url"
    static let pending = "pending"
    static let plan = "plan"
    static let publicKey = "publicKey"
    static let name = "name"
    static let watch = "watch"
    static let clientID = "clientId"
    static let clientSecret = "clientSecret"

    /// What WatchConnectivity carries in one message or context, with room to spare.
    static let limit = 60_000
    /// Mono 16-bit PCM at 16 kHz: 32 KB/s, 6x less than 48 kHz Float32. The watch records in
    /// 1/4-second pieces; when the phone or the runner falls behind, it sends the backlog up to
    /// 1 second a chunk. Listening stops by itself after `voiceSeconds`.
    static let voiceSampleRate = 16_000.0
    static let voiceSampleBytes = 2
    static let chunkLimit = 32_000
    static let voiceSeconds = 60
}
#endif
