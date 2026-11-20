import SwiftUI

/// Confirmation sheet for File Management. One view covers three scopes via Mode: movie, entire series, or selected seasons. The server is the final authority; a 403 during a stale-policy window surfaces as the partial-failure toast. Rows use BoolPillRow and footer buttons GlassActionButton because native Toggle/.bordered rendered invisible labels under tvOS focus.
struct MediaDeletionSheet: View {
    /// Scope of the deletion. The view's body branches on this.
    enum Mode: Equatable {
        case movie(itemID: String, tmdbID: Int?, title: String)
        case series(itemID: String, tmdbID: Int?, title: String, seasons: [SeasonOption])
    }

    /// One season-picker row; `id` is the season's Jellyfin item id, `title` the localised "Season 1"/"Specials" Jellyfin returns.
    struct SeasonOption: Identifiable, Equatable {
        let id: String
        let seasonNumber: Int
        let title: String
    }

    let mode: Mode
    /// Invoked on confirm; the sheet stays open until its async work completes (the sheet self-dismisses on success, see performDelete).
    let onConfirm: (DeletionRequest) async -> DeletionOutcome
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Tighter sheet inset on a phone so the footer buttons keep their full labels; tvOS/iPad keep the roomy 48pt plate.
    private var contentInset: CGFloat { hSizeClass == .compact ? 24 : 48 }

    /// seasonItemIDs is empty for movie + entire-series.
    struct DeletionRequest {
        let cascadeToArrStack: Bool
        let deleteEntireSeries: Bool
        let seasonItemIDs: [String]
    }

    /// Parent's report back; picks the toast (or dismiss on success).
    enum DeletionOutcome: Equatable {
        case success
        case partialSuccess(message: String)
        case failure(message: String)
    }

    // MARK: - Local state

    @State private var cascadeToArrStack: Bool = true
    @State private var deleteEntireSeries: Bool = false
    @State private var selectedSeasonIDs: Set<String> = []
    @State private var isDeleting: Bool = false
    @State private var toast: DeletionOutcome?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 28) {
                header

                switch mode {
                case .movie:
                    movieBody
                case .series(_, _, _, let seasons):
                    seriesBody(seasons: seasons)
                }

                Spacer()

                footer
            }
            .padding(contentInset)
            .frame(maxWidth: 800)

            // Outcome toast; in-flight feedback is on the Delete button itself (GlassActionButton isLoading).
            if let toast = toast {
                toastView(toast)
                    .padding(.bottom, 24)
                    .padding(.horizontal, contentInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("delete.confirm.title")
                .font(.title2)
                .fontWeight(.semibold)
            Text(titleSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var titleSubtitle: String {
        switch mode {
        case .movie(_, _, let title): return title
        case .series(_, _, let title, _): return title
        }
    }

    private var movieBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            cascadePillRow(disabled: false)
            Text("delete.confirm.movie.body")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesBody(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BoolPillRow(
                title: "delete.confirm.series.entire",
                isOn: $deleteEntireSeries,
                disabled: false
            )
            .onAppear {
                // Force cascade off for the INITIAL disabled state: the cascadePillRow onChange never fires for it, else the parent could get cascade=true with a seasons-only selection.
                if !deleteEntireSeries { cascadeToArrStack = false }
            }
            .onChange(of: deleteEntireSeries) { _, newValue in
                // Whole-series clears any season selection.
                if newValue { selectedSeasonIDs.removeAll() }
            }

            if !deleteEntireSeries {
                seasonList(seasons: seasons)
            }

            cascadePillRow(disabled: !deleteEntireSeries)

            if !deleteEntireSeries {
                Text("delete.confirm.cascade.seasonsFootnote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cascadePillRow(disabled: Bool) -> some View {
        BoolPillRow(
            title: "delete.confirm.cascade.title",
            isOn: $cascadeToArrStack,
            disabled: disabled
        )
        .onChange(of: disabled) { _, isDisabled in
            // Force off when disabled so the parent never sees cascade=true with seasons-only.
            if isDisabled { cascadeToArrStack = false }
        }
    }

    private func seasonList(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("delete.confirm.series.seasons")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            // Bounded scroll: many-season series (One Piece, 11+) overflowed the sheet and pushed the footer off-screen. ViewThatFits instead of a per-row height estimate: the old `count * 64` cap undershot a tvOS row and clipped a single season in half.
            ViewThatFits(in: .vertical) {
                seasonRows(seasons: seasons)
                ScrollView {
                    seasonRows(seasons: seasons)
                }
            }
            .frame(maxHeight: 420)
        }
    }

    private func seasonRows(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(seasons) { season in
                BoolPillRow(
                    title: LocalizedStringKey(season.title),
                    isOn: Binding(
                        get: { selectedSeasonIDs.contains(season.id) },
                        set: { isOn in
                            if isOn {
                                selectedSeasonIDs.insert(season.id)
                            } else {
                                selectedSeasonIDs.remove(season.id)
                            }
                        }
                    ),
                    disabled: false
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 24) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: { dismiss() }
            )
            .disabled(isDeleting)

            GlassActionButton(
                title: "delete.confirm.deleteButton",
                systemImage: "trash",
                isProminent: true,
                isDestructive: true,
                isLoading: isDeleting,
                action: { Task { await performDelete() } }
            )
            .disabled(isDeleting || !canConfirm)
        }
    }

    private func toastView(_ outcome: DeletionOutcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .success:
                return (String(localized: "delete.toast.success"), .green)
            case .partialSuccess(let msg):
                return (msg, .orange)
            case .failure(let msg):
                return (msg, .red)
            }
        }()
        return Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - State helpers

    /// True when at least one valid deletion target is selected.
    private var canConfirm: Bool {
        switch mode {
        case .movie:
            return true
        case .series:
            return deleteEntireSeries || !selectedSeasonIDs.isEmpty
        }
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }

        let request = DeletionRequest(
            cascadeToArrStack: cascadeToArrStack,
            deleteEntireSeries: {
                if case .movie = mode { return false }
                return deleteEntireSeries
            }(),
            seasonItemIDs: deleteEntireSeries ? [] : Array(selectedSeasonIDs)
        )
        let outcome = await onConfirm(request)
        toast = outcome
        if case .success = outcome {
            // Brief success hold before auto-dismiss; failure/partial toasts stay until Cancel.
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

extension MediaDeletionSheet.DeletionOutcome {
    /// Maps a thrown deletion error onto a toast outcome, shared by Movie/SeriesDetailView: Seerr-not-signed-in and partial failures become partialSuccess, everything else the generic failure.
    static func from(_ error: Error) -> Self {
        if let error = error as? MediaDeletionError {
            if error.reason == .seerrNotSignedIn {
                return .partialSuccess(
                    message: String(localized: "delete.toast.seerrNotSignedIn")
                )
            }
            if error.partialSuccess {
                return .partialSuccess(
                    message: String(localized: "delete.toast.partialSuccess")
                )
            }
        }
        return .failure(
            message: String(localized: "delete.toast.failure")
        )
    }
}

// MARK: - BoolPillRow

/// Focus-friendly inline toggle (mirrors ValuePickerRow). Uses .focusable(true) not Button: tvOS Button focus chrome bleeds through .focusEffectDisabled() over .ultraThinMaterial, so the raw surface lets the accent stroke be the only focus indicator.
private struct BoolPillRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var disabled: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        // Background + stroke read `.tint` from the environment (SodaliteApp's WindowGroup .tint(effectiveTint(...))). Never Color.accentColor: that reads the static AccentColor asset (hard-coded blue), not the per-session tint.
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18)) : AnyShapeStyle(Color.Theme.restFill))
        )
        .focusStroke(cornerRadius: 16, isFocused: focused)
        .focusResponse(.inline.withShadow(opacity: 0.25, radius: 10, y: 5), isFocused: focused)
        .focusableSurface(!disabled)
        .focused($focused)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .stableTap(isFocused: focused) {
            if !disabled { isOn.toggle() }
        }
    }
}
