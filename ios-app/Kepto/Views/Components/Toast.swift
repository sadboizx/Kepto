import SwiftUI

/// One non-blocking notice: a dark pill that appears (top, below the
/// status area) and dismisses itself after ~2.5s. Replaces the old
/// blocking `.alert` on `uploadNotice` / `saveNotice` /
/// `shareSaveNotice` — the user never has to tap OK to keep working.
/// Owned by `LibraryViewModel` (`toast`) so every tab shares the same
/// toast; the app root (`KeptoApp`) renders it.
struct ToastState: Identifiable {
    let id = UUID()
    let message: String
    var isError = false
    /// Optional retry action (e.g. Save to Photos failed → "Thử lại").
    /// A plain sync closure — async work wraps itself in a Task.
    var retryTitle: String?
    var retry: (() -> Void)?

    /// Explicit init (not the synthesized memberwise one): the
    /// defaulted properties are assigned here, so call sites never
    /// hit the memberwise-init trap.
    init(message: String, isError: Bool = false, retryTitle: String? = nil, retry: (() -> Void)? = nil) {
        self.message = message
        self.isError = isError
        self.retryTitle = retryTitle
        self.retry = retry
    }
}

/// Dark capsule toast: message + optional Retry button. No dismiss
/// button — it auto-dismisses (the ViewModel owns the timer).
struct ToastView: View {
    let toast: ToastState
    var onRetry: () -> Void = {}
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if toast.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
            if let retryTitle = toast.retryTitle {
                Button(retryTitle) { onRetry() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.blue)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .onTapGesture { onTap() }
    }
}
