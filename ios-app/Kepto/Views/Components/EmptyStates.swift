import SwiftUI

/// Empty and loading states ported from Photos' `EmptyStates.swift`.
///
/// Photos' `LimitedAccessBanner` is deliberately NOT ported — it is
/// the PhotoKit limited-access flow (manage which photos the app may
/// see) and Kepto has no PhotoKit permission flow at all.

/// Loading state: spinner + line. Photos' `LoadingLibraryView`,
/// unchanged except the label comes from L10n (step 9).
struct LoadingLibraryView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.loading)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
