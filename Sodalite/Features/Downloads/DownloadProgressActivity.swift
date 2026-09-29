#if os(iOS)
import BackgroundTasks
import Foundation

/// The system's progress activity for running downloads (Sodalite#81): a `BGContinuedProcessingTask`,
/// which iOS draws in the Dynamic Island and on the Lock Screen and which keeps the app awake long
/// enough to feed it. The transfers themselves stay on the background URLSession, so the activity
/// is only a view of them: when the system ends it early, or the viewer dismisses it, the downloads
/// carry on and the Downloads tab still shows them.
///
/// It may only start from something the viewer just did (Apple's rule for this task type), so
/// `begin()` is called from the download, resume and retry buttons and nowhere else.
@MainActor
final class DownloadProgressActivity {
    static let identifier = "de.superuser404.Sodalite.downloads.progress"

    private let store: DownloadStore
    private let liveProgress: () -> [String: Double]
    private var batch: Set<String> = []
    private var isRegistered = false
    private var isSubmitted = false
    private var task: BGContinuedProcessingTask?
    private var feed: Task<Void, Never>?

    init(store: DownloadStore, liveProgress: @escaping () -> [String: Double]) {
        self.store = store
        self.liveProgress = liveProgress
    }

    /// Adds whatever is queued or running to the batch, and shows the activity if it is not up yet.
    func begin() {
        batch.formUnion(store.items.values
            .filter { $0.manifest.state == .queued || $0.manifest.state == .downloading }
            .map(\.id))
        guard !isSubmitted, !batch.isEmpty else { return }
        register()
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.identifier,
            title: String(localized: "tab.downloads"),
            subtitle: subtitle(for: summary()))
        // Only now or never: an activity that shows up minutes later describes a queue that moved on.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            isSubmitted = true
        } catch {
            LogTap.shared.note("[Downloads] progress activity not shown: \(error)")
        }
    }

    private func register() {
        guard !isRegistered else { return }
        // @Sendable, or Swift 6 infers this closure main-actor isolated from the class around it,
        // and BackgroundTasks calls it on a queue of its own: the isolation check traps (crashed the
        // first download on the device, 2026-09-29).
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { @Sendable [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            nonisolated(unsafe) let handed = continued
            Task { @MainActor in self?.run(handed) }
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        self.task = task
        // Called on a system queue too, so not main-actor isolated either.
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.end(success: false) }
        }
        feed = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.update() else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Pushes the current numbers; false once the batch is done and the task was completed.
    private func update() -> Bool {
        guard let task else { return false }
        guard let summary = summary() else {
            end(success: true)
            return false
        }
        show(summary, on: task)
        // The final numbers go out BEFORE completing: the system keeps the last subtitle on the
        // finished activity, which otherwise read "0 of 1" under the checkmark.
        if summary.isDone {
            end(success: true)
            return false
        }
        return true
    }

    private func show(_ summary: DownloadActivitySummary, on task: BGContinuedProcessingTask) {
        // Bytes where the sizes are known, items otherwise: a transcode has no size until it ends.
        if summary.totalBytes > 0 {
            task.progress.totalUnitCount = summary.totalBytes
            task.progress.completedUnitCount = summary.isDone
                ? summary.totalBytes : min(summary.receivedBytes, summary.totalBytes)
        } else {
            task.progress.totalUnitCount = Int64(summary.total)
            task.progress.completedUnitCount = Int64(summary.finished)
        }
        task.updateTitle(String(localized: "tab.downloads"), subtitle: subtitle(for: summary))
    }

    private func end(success: Bool) {
        feed?.cancel()
        feed = nil
        task?.setTaskCompleted(success: success)
        task = nil
        isSubmitted = false
        batch = []
    }

    private func summary() -> DownloadActivitySummary? {
        DownloadActivitySummary.make(batch: batch, items: Array(store.items.values), liveProgress: liveProgress())
    }

    private func subtitle(for summary: DownloadActivitySummary?) -> String {
        guard let summary else { return "" }
        guard summary.totalBytes > 0 else {
            return String(localized: "downloads.activity.count \(summary.finished) \(summary.total)")
        }
        let received = summary.receivedBytes.formatted(.byteCount(style: .file))
        let total = summary.totalBytes.formatted(.byteCount(style: .file))
        return String(localized: "downloads.activity.subtitle \(summary.finished) \(summary.total) \(received) \(total)")
    }
}
#endif
