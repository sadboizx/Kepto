import SwiftUI

/// Task Manager ("Hoạt động"): every in-flight save, collection
/// import, and file upload in one place. Opens from the activity
/// button in the Library toolbar (visible only while a task is
/// running, waiting, or failed). A sheet — the grid behind it stays
/// live and never blocks.
///
/// Sections: Đang chạy / Chờ mạng / Lỗi (per-task Retry) / Xong gần
/// đây (done tasks prune themselves after ~30s). Failed rows can be
/// swiped away; removing a task also drops its kept retry source
/// (see `LibraryViewModel.cleanupRetrySource`).
struct ActivitySheet: View {
    @EnvironmentObject private var taskStore: TaskStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if taskStore.tasks.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.activityEmpty, systemImage: "bolt")
                    }
                } else {
                    List {
                        if !running.isEmpty {
                            Section(L10n.activityRunning) {
                                ForEach(running) { task in
                                    ActivityRow(task: task)
                                }
                            }
                        }
                        if !waiting.isEmpty {
                            Section(L10n.activityWaiting) {
                                ForEach(waiting) { task in
                                    ActivityRow(task: task)
                                }
                            }
                        }
                        if !failed.isEmpty {
                            Section(L10n.activityFailed) {
                                ForEach(failed) { task in
                                    ActivityRow(task: task)
                                }
                                .onDelete { indexSet in
                                    for index in indexSet {
                                        taskStore.removeTask(id: failed[index].id)
                                    }
                                }
                            }
                        }
                        if !done.isEmpty {
                            Section(L10n.activityDone) {
                                ForEach(done) { task in
                                    ActivityRow(task: task)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.activity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
    }

    private var running: [ActivityTask] { taskStore.tasks.filter { $0.state == .running } }
    private var waiting: [ActivityTask] { taskStore.tasks.filter { $0.state == .waitingForNetwork } }
    private var failed: [ActivityTask] { taskStore.tasks.filter { $0.state == .failed } }
    private var done: [ActivityTask] { taskStore.tasks.filter { $0.state == .done } }
}

/// One row: kind icon, title, state line (progress or error), and a
/// Retry button for failed tasks that still have a retry closure.
private struct ActivityRow: View {
    let task: ActivityTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .lineLimit(1)
                    .font(.subheadline)
                Text(subtitle)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if task.state == .running, (task.byteProgress != nil || task.kind == .collection) {
                    ProgressView(value: task.progress)
                        .tint(.white)
                }
            }
            Spacer()
            if task.state == .failed, task.retry != nil {
                Button(L10n.retry) {
                    Task { await task.retry?() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var iconName: String {
        switch task.state {
        case .waitingForNetwork: return "icloud.slash"
        case .failed: return "exclamationmark.circle"
        case .done: return "checkmark.circle"
        case .running:
            switch task.kind {
            case .link: return "link"
            case .collection: return "rectangle.stack"
            case .upload: return "arrow.up.circle"
            }
        }
    }

    private var iconColor: Color {
        switch task.state {
        case .failed: return .red
        case .done: return .green
        case .waitingForNetwork: return .orange
        case .running: return .white
        }
    }

    private var subtitle: String {
        switch task.state {
        case .running:
            if task.kind == .collection, task.total > 1 {
                return "\(task.done)/\(task.total)"
            }
            if task.byteProgress != nil {
                return "\(Int(task.progress * 100))%"
            }
            return L10n.activityRunning
        case .waitingForNetwork:
            return task.errorText ?? L10n.waitingForNetwork
        case .failed:
            return task.errorText ?? L10n.activityFailed
        case .done:
            return L10n.activityDone
        }
    }
}
