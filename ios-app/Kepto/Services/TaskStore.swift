import Foundation
import Network

/// Kind of background work the Task Manager ("Hoạt động") tracks.
enum ActivityTaskKind: String, Codable {
    /// One pasted/shared link (POST /api/save, single item).
    case link
    /// A collection link (POST /api/save-collection, up to 100 items).
    case collection
    /// One file uploading from the device (PhotosPicker / Files).
    case upload
    /// One file downloading from the cloud (Save to Photos).
    case download
}

/// Lifecycle of one task. `done` tasks are pruned shortly after
/// finishing so the sheet never becomes a mailbox.
enum ActivityTaskState: String, Codable {
    case running
    case waitingForNetwork
    case failed
    case done
}

/// One row in the Task Manager. `retry` is an in-session closure
/// only — it is never persisted (link tasks re-attach it on restore).
struct ActivityTask: Identifiable {
    let id: UUID
    var kind: ActivityTaskKind
    /// Row title: file name for uploads, link or collection title
    /// for saves.
    var title: String
    /// Link tasks: the URL, so Retry can re-save it.
    var url: String?
    /// Items this task created (single: 1 id; collection: up to 100).
    var itemIDs: [String]
    /// Collection total (number of videos); 1 for single/link/upload.
    var total: Int
    /// How many are finished (collection: ready/failed items seen in
    /// the Library page; upload: 0 or 1).
    var done: Int
    var state: ActivityTaskState
    var errorText: String?
    /// Byte progress (0...1) for uploads; nil = use done/total.
    var byteProgress: Double?
    var createdAt: Date
    /// Retry this task (re-save the link / re-upload the file).
    /// Set by the ViewModel, which owns the retry sources.
    var retry: (() async -> Void)?

    /// Overall progress for the row's bar: byte progress for uploads,
    /// done/total otherwise.
    var progress: Double {
        if let byteProgress { return min(max(byteProgress, 0), 1) }
        guard total > 0 else { return 0 }
        return min(Double(done) / Double(total), 1)
    }

    /// Explicit init (not the synthesized memberwise one): the
    /// defaulted properties are assigned here, so call sites never
    /// hit the memberwise-init trap.
    init(
        id: UUID = UUID(),
        kind: ActivityTaskKind,
        title: String,
        url: String? = nil,
        itemIDs: [String] = [],
        total: Int = 1,
        done: Int = 0,
        state: ActivityTaskState = .running,
        errorText: String? = nil,
        byteProgress: Double? = nil,
        createdAt: Date = Date(),
        retry: (() async -> Void)? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.itemIDs = itemIDs
        self.total = total
        self.done = done
        self.state = state
        self.errorText = errorText
        self.byteProgress = byteProgress
        self.createdAt = createdAt
        self.retry = retry
    }
}

/// What a link/collection task persists as (UserDefaults JSON).
/// Upload tasks are NOT persisted — their temp files are gone after
/// a kill, so a fake resume would be a lie (see the ViewModel).
struct PersistedLinkTask: Codable {
    var url: String
    var itemIDs: [String]
    var total: Int
    var done: Int
    var createdAt: Date
    var isCollection: Bool
}

/// The Task Manager store: background tasks (link saves, collection
/// saves, file uploads), offline state, and link-task persistence.
/// Owned by `LibraryViewModel` (`taskStore`) and injected into the
/// environment by the app root, so the Library top bar and the
/// Activity sheet read the same store.
///
/// Threading: @MainActor — every mutation runs on the main actor.
/// `NWPathMonitor` callbacks hop back via `Task { @MainActor }`.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [ActivityTask] = []
    /// True while the network path is unsatisfied.
    @Published private(set) var isOffline = false

    /// Called when a task leaves the store (done-pruned, retried,
    /// dismissed) — the ViewModel deletes kept temp files for upload
    /// retries here. Set by the ViewModel; weak capture on its side.
    var onTaskRemoved: ((UUID) -> Void)?

    private let monitor = NWPathMonitor()
    private var connectivityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pruneTasks: [UUID: Task<Void, Never>] = [:]
    private let persistedKey = "kepto.persistedLinkTasks.v1"

    var hasVisibleTasks: Bool {
        tasks.contains { $0.state == .running || $0.state == .waitingForNetwork || $0.state == .failed }
    }

    var hasRunningTasks: Bool { tasks.contains { $0.state == .running } }

    /// Aliases the views read (activity button icon + spin).
    var isAnyRunning: Bool { hasRunningTasks }
    var isAnyWaiting: Bool { tasks.contains { $0.state == .waitingForNetwork } }

    var runningTasks: [ActivityTask] { tasks.filter { $0.state == .running } }
    var waitingTasks: [ActivityTask] { tasks.filter { $0.state == .waitingForNetwork } }
    var failedTasks: [ActivityTask] { tasks.filter { $0.state == .failed } }
    var doneTasks: [ActivityTask] { tasks.filter { $0.state == .done } }

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Mutation (all persist link tasks)

    @discardableResult
    func addTask(_ task: ActivityTask) -> UUID {
        tasks.append(task)
        persistLinkTasks()
        return task.id
    }

    func updateTask(id: UUID, _ mutate: (inout ActivityTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        if tasks[index].state == .done { schedulePrune(id: id) }
        if tasks[index].kind == .link || tasks[index].kind == .collection { persistLinkTasks() }
    }

    func setState(id: UUID, _ state: ActivityTaskState, errorText: String? = nil) {
        updateTask(id: id) {
            $0.state = state
            if let errorText { $0.errorText = errorText }
        }
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        pruneTasks[id]?.cancel()
        pruneTasks.removeValue(forKey: id)
        persistLinkTasks()
        onTaskRemoved?(id)
    }

    /// Done tasks linger briefly so the user can see them finish,
    /// then leave on their own (30s). Failed/waiting tasks never
    /// auto-prune — the user dismisses them or retries.
    private func schedulePrune(id: UUID) {
        guard pruneTasks[id] == nil else { return }
        pruneTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self else { return }
            if self.tasks.first(where: { $0.id == id })?.state == .done {
                self.removeTask(id: id)
            }
        }
    }

    // MARK: - Connectivity (NWPathMonitor, iOS 12+)

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOffline = offline
                if !offline { self.resumeConnectivityWaiters() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "kepto.pathmonitor", qos: .background))
    }

    private func resumeConnectivityWaiters() {
        let waiters = connectivityWaiters
        connectivityWaiters.removeAll()
        for (_, continuation) in waiters { continuation.resume() }
    }

    /// Suspends until the network path is satisfied again. Returns at
    /// once when already online. Never spins: one continuation per
    /// waiter, resumed exactly once (by the path update or by
    /// cancellation).
    func waitForConnectivity() async {
        guard isOffline else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The path may have come back between the guard and
                // here — resume at once instead of waiting forever.
                if Task.isCancelled || !isOffline {
                    continuation.resume()
                } else {
                    connectivityWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = self.connectivityWaiters.removeValue(forKey: id) {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Persistence (link + collection tasks only)

    func loadPersistedLinkTasks() -> [PersistedLinkTask] {
        guard let data = UserDefaults.standard.data(forKey: persistedKey),
              let records = try? JSONDecoder().decode([PersistedLinkTask].self, from: data)
        else { return [] }
        return records
    }

    /// Writes the currently tracked link/collection tasks (running,
    /// waiting, failed — never done, never uploads) to UserDefaults.
    /// Called on every link-task mutation; upload progress ticks do
    /// not touch it (see updateTask).
    func persistLinkTasks() {
        let records = tasks
            .filter { ($0.kind == .link || $0.kind == .collection) && $0.state != .done }
            .map {
                PersistedLinkTask(
                    url: $0.url ?? "",
                    itemIDs: $0.itemIDs,
                    total: $0.total,
                    done: $0.done,
                    createdAt: $0.createdAt,
                    isCollection: $0.kind == .collection
                )
            }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: persistedKey)
    }
}
