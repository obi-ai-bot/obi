import Foundation
import OSLog

/// Hears when a job ends even while Oby is suspended, so the Live Activity can say how it ended:
/// a background download of `GET /v1/jobs/{id}/wait` per running job. iOS keeps those going
/// after Oby is suspended and wakes Oby when the runner answers (`ObyPhoneApp`'s background task).
// ponytail: the end only, not each step; steps in the background need push (F11). Each job is
// waited on once per launch, so a wait the runner drops (a restart) isn't retried.
final class JobWaiter: NSObject, URLSessionDownloadDelegate {
    static let shared = JobWaiter()
    static let identifier = "com.deskree.oby.jobs"
    private var waited: Set<URL> = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        // The runner answers when the job ends, which can take hours.
        config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Waits on each running job that isn't waited on yet. Called while Oby is open, so iOS starts
    /// the downloads right away rather than when it sees fit.
    func wait(for jobs: [Job], runner: URL) {
        let urls = jobs.filter(\.isActive).map { runner.appending(path: "v1/jobs/\($0.id)/wait") }.filter { waited.insert($0).inserted }
        guard !urls.isEmpty else { return }
        Task {
            // Downloads from before a relaunch carry on; don't start them twice.
            let pending = Set(await session.allTasks.compactMap(\.originalRequest?.url))
            for url in urls where !pending.contains(url) { session.downloadTask(with: Self.request(url)).resume() }
        }
    }

    /// The wait with this iPhone's device token, as every gateway request carries (Phone.runner):
    /// without it the gateway answers 401 at once.
    static func request(_ url: URL, token: String? = GatewayTokenStore.read()) -> URLRequest {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// iOS woke Oby for this session's events: the session has to exist to receive them.
    func reconnect() { _ = session }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { Logger.phone.error("waiting on a job failed: \(error.localizedDescription, privacy: .public)") }
    }
}
